import Foundation

let VOICED = [Float](repeating: 0.1, count: 16000)
let SILENT = [Float](repeating: 0.0, count: 16000)

/// Never resumes and ignores cancellation — like a cold CoreML/MLX load. The delay-based fakes are cancellable,
/// which let a task-group "timeout" pass in tests while blocking for the whole load in production.
private func hangForever() async {
    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
}

struct TestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class FakeRecorder: RecorderLike {
    let pcm: [Float]
    let armError: Error?
    private(set) var armed = false

    init(pcm: [Float] = VOICED, armError: Error? = nil) {
        self.pcm = pcm
        self.armError = armError
    }

    func arm() throws {
        if let armError { throw armError }
        armed = true
    }

    func disarm() -> [Float] {
        armed = false
        return pcm
    }
}

final class FakeStt: SttEngine {
    let name = "parakeet"
    let text: String
    let err: Error?
    let hang: Bool
    private(set) var calls = 0

    init(text: String = "so um hello there world", err: Error? = nil, hang: Bool = false) {
        self.text = text
        self.err = err
        self.hang = hang
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        calls += 1
        if hang { await hangForever() }
        if let err { throw err }
        return text
    }
}

final class FakeCleaner: CleanupBackend {
    let out: String
    let err: Error?
    let delay: Double
    let hang: Bool
    /// Fires when the call is cancelled mid-delay, proving a timed-out cleanup is told to stop.
    let onCancel: (() -> Void)?
    private(set) var calls = 0
    // Inputs seen by clean(), so tests can assert what the model received.
    private(set) var received: [String] = []

    init(
        out: String = "hello there world", err: Error? = nil, delay: Double = 0.0, hang: Bool = false,
        onCancel: (() -> Void)? = nil
    ) {
        self.out = out
        self.err = err
        self.delay = delay
        self.hang = hang
        self.onCancel = onCancel
    }

    func clean(_ text: String) async throws -> String {
        calls += 1
        received.append(text)
        if hang { await hangForever() }
        if delay > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                onCancel?()
                throw error
            }
        }
        if let err { throw err }
        return out
    }
}

final class FakePaster: Pasting {
    let err: Error?
    private(set) var pasted: [String] = []
    /// The key-down app each paste was given, in call order.
    private(set) var targets: [pid_t?] = []

    init(err: Error? = nil) {
        self.err = err
    }

    func paste(_ text: String, target: pid_t?) throws {
        if let err { throw err }
        pasted.append(text)
        targets.append(target)
    }
}

final class FakeClock {
    var t: Double = 0.0
    func now() -> Double { t }
}

/// Accumulates values from test closures (onState, onNotice, saveFailedAudio) for the test to read back.
final class Box<T> {
    private(set) var value: [T] = []
    func append(_ v: T) { value.append(v) }
}

/// A `CleanupModelBackend` whose `preload()` can be held open, so a test drives the cancel/supersede/commit
/// orderings of a model switch deterministically instead of racing real timing.
final class FakeCleanupModelBackend: CleanupModelBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _loaded: Bool
    private var _holdsMemory: Bool
    private var _preloadCalls = 0
    private var _unloadCalls = 0
    private var _dictionaries: [DictionarySnapshot] = []
    private var _events: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var gateReleased = false
    private let gated: Bool

    init(loaded: Bool = false, gatedPreload: Bool = false, holdsMemory: Bool = true) {
        _loaded = loaded
        gated = gatedPreload
        _holdsMemory = holdsMemory
    }

    var loaded: Bool {
        get { lock.withLock { _loaded } }
        set { lock.withLock { _loaded = newValue } }
    }
    var preloadCalls: Int { lock.withLock { _preloadCalls } }
    var unloadCalls: Int { lock.withLock { _unloadCalls } }
    var dictionaries: [DictionarySnapshot] { lock.withLock { _dictionaries } }
    /// "setDictionary", "preload", "unload" in call order.
    var events: [String] { lock.withLock { _events } }
    var holdsMemory: Bool { lock.withLock { _holdsMemory } }

    var isLoaded: Bool { get async { lock.withLock { _loaded } } }

    func setDictionary(_ snapshot: DictionarySnapshot) {
        lock.withLock {
            _dictionaries.append(snapshot)
            _events.append("setDictionary")
        }
    }

    func preload() async {
        lock.withLock {
            _preloadCalls += 1
            _events.append("preload")
        }
        guard gated else { return }
        // Ignores cancellation, like a real model load.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if gateReleased { return true }
                gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Lets a held `preload()` return, optionally deciding whether the model ends up loaded.
    func releasePreload(loaded: Bool? = nil) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let loaded { _loaded = loaded }
            gateReleased = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }

    func unload() async {
        lock.withLock {
            _unloadCalls += 1
            _loaded = false
            _events.append("unload")
        }
    }

    func clean(_ text: String) async throws -> String { text }
}

/// Polls main-actor state in 1 ms steps (bounded at ~1 s) so a test waits on a condition, never a fixed delay.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

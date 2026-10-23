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

final class FakeRecorder: RecorderLike, RecorderPreparing {
    let pcm: [Float]
    /// Settable so a test can fail one start and let the next succeed.
    var armError: Error?
    private(set) var armed = false
    var prewarmError: Error?
    private(set) var prewarmCalls = 0
    private(set) var preferredInputs: [String?] = []

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

    func prewarm() throws {
        prewarmCalls += 1
        if let prewarmError { throw prewarmError }
    }

    func setPreferredInput(uid: String?) {
        preferredInputs.append(uid)
    }
}

final class FakeStt: SttEngine {
    let name = "parakeet"
    let text: String
    let err: Error?
    let hang: Bool
    /// Runs inside transcribe, so a test can move the fake clock by "STT time".
    let onTranscribe: (() -> Void)?
    private(set) var calls = 0
    // Audio as received, so tests can assert an enhancer ran before transcription.
    private(set) var received: [[Float]] = []

    init(
        text: String = "so um hello there world", err: Error? = nil, hang: Bool = false,
        onTranscribe: (() -> Void)? = nil
    ) {
        self.text = text
        self.err = err
        self.hang = hang
        self.onTranscribe = onTranscribe
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        calls += 1
        received.append(pcm)
        onTranscribe?()
        if hang { await hangForever() }
        if let err { throw err }
        return text
    }
}

final class FakeEnhancer: AudioEnhancer {
    let out: [Float]
    let err: Error?
    let delay: Double
    let hang: Bool
    /// Runs inside enhance, so a test can move the fake clock by "enhance time".
    let onEnhance: (() -> Void)?
    /// Fires when the call is cancelled mid-delay, proving a timed-out enhance is told to stop.
    let onCancel: (() -> Void)?
    private(set) var calls = 0
    private(set) var received: [[Float]] = []

    init(
        out: [Float] = [Float](repeating: 0.5, count: 16000), err: Error? = nil, delay: Double = 0.0,
        hang: Bool = false, onEnhance: (() -> Void)? = nil, onCancel: (() -> Void)? = nil
    ) {
        self.out = out
        self.err = err
        self.delay = delay
        self.hang = hang
        self.onEnhance = onEnhance
        self.onCancel = onCancel
    }

    func enhance(_ pcm: [Float]) async throws -> [Float] {
        calls += 1
        received.append(pcm)
        onEnhance?()
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

final class FakeKeyPresser: KeyPressing {
    let err: Error?
    private(set) var pressed: [SyntheticKey] = []
    /// The key-down app each press was given, in call order.
    private(set) var targets: [pid_t?] = []

    init(err: Error? = nil) {
        self.err = err
    }

    func press(_ key: SyntheticKey, target: pid_t?) throws {
        if let err { throw err }
        pressed.append(key)
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
    private var _onIsLoaded: (@MainActor () -> Void)?
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
    var holdsMemory: Bool {
        get { lock.withLock { _holdsMemory } }
        set { lock.withLock { _holdsMemory = newValue } }
    }

    /// Runs on the main actor inside `isLoaded`, i.e. at the suspension point a caller awaits: lets a test land a
    /// cancellation, a revert or a newer switch there.
    var onIsLoaded: (@MainActor () -> Void)? {
        get { lock.withLock { _onIsLoaded } }
        set { lock.withLock { _onIsLoaded = newValue } }
    }

    var isLoaded: Bool {
        get async {
            if let hook = onIsLoaded { await MainActor.run { hook() } }
            return lock.withLock { _loaded }
        }
    }

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

/// An `UnloadableEngine` whose `preload()` can be held open, so a test drives the cancel/supersede/commit
/// orderings of an engine switch deterministically. Unlike the cleanup backend, one engine instance is shared by
/// every switch to it, so several held preloads can wait on the same gate (as `LazyModel` coalesces them).
final class FakeUnloadableEngine: UnloadableEngine, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var _loaded: Bool
    private var _preloadCalls = 0
    private var _unloadCalls = 0
    private var _onIsLoaded: (@MainActor () -> Void)?
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var gateReleased = false

    init(name: String, loaded: Bool = false) {
        self.name = name
        _loaded = loaded
    }

    var loaded: Bool {
        get { lock.withLock { _loaded } }
        set { lock.withLock { _loaded = newValue } }
    }
    var preloadCalls: Int { lock.withLock { _preloadCalls } }
    var unloadCalls: Int { lock.withLock { _unloadCalls } }

    /// Runs on the main actor inside `isLoaded`, i.e. at the suspension point a controller awaits: lets a test
    /// land a revert or a newer switch there.
    var onIsLoaded: (@MainActor () -> Void)? {
        get { lock.withLock { _onIsLoaded } }
        set { lock.withLock { _onIsLoaded = newValue } }
    }

    var isLoaded: Bool {
        get async {
            if let hook = onIsLoaded { await MainActor.run { hook() } }
            return lock.withLock { _loaded }
        }
    }

    func preload() async {
        lock.withLock { _preloadCalls += 1 }
        // Ignores cancellation, like a real model load.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if gateReleased { return true }
                gates.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Lets every held `preload()` return, optionally deciding whether the model ends up loaded.
    func releasePreload(loaded: Bool? = nil) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            if let loaded { _loaded = loaded }
            gateReleased = true
            defer { gates = [] }
            return gates
        }
        for continuation in waiting { continuation.resume() }
    }

    func unload() async {
        lock.withLock {
            _unloadCalls += 1
            _loaded = false
        }
    }

    func transcribe(_ pcm: [Float]) async throws -> String { "fake transcript" }
}

/// A LocalVQE stand-in: returns `out`, or throws `err`, and records what it was given.
final class FakeVqe: VqeProcessing, @unchecked Sendable {
    let out: [Float]
    let err: Error?
    private let lock = NSLock()
    private var _received: [[Float]] = []

    init(out: [Float] = [Float](repeating: 0.5, count: 16000), err: Error? = nil) {
        self.out = out
        self.err = err
    }

    var received: [[Float]] { lock.withLock { _received } }

    func process(mic: [Float]) async throws -> [Float] {
        lock.withLock { _received.append(mic) }
        if let err { throw err }
        return out
    }
}

/// The enhancer's model factory, with the load held open until `release()` so a test drives what happens while
/// a load is in flight, like `FakeUnloadableEngine`. The first `failFirst` calls throw after reporting progress.
final class FakeVqeFactory: @unchecked Sendable {
    let vqe: FakeVqe
    private let failFirst: Int
    private let lock = NSLock()
    private var _calls = 0
    private var gated: Bool
    private var gates: [CheckedContinuation<Void, Never>] = []

    init(vqe: FakeVqe = FakeVqe(), failFirst: Int = 0, gated: Bool = false) {
        self.vqe = vqe
        self.failFirst = failFirst
        self.gated = gated
    }

    var calls: Int { lock.withLock { _calls } }

    func make(progress: @escaping @Sendable (Double) -> Void) async throws -> any VqeProcessing {
        let call = lock.withLock { () -> Int in
            _calls += 1
            return _calls
        }
        progress(0.5)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if !gated { return true }
                gates.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        if call <= failFirst { throw TestError(message: "download failed") }
        return vqe
    }

    /// Lets every held load finish, and any later one run straight through.
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            gated = false
            defer { gates = [] }
            return gates
        }
        for continuation in waiting { continuation.resume() }
    }
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

/// Scripted TCC answers; `requestMicrophone` can flip the answer the way the user's click does.
final class FakeTCCProbe: TCCProbing {
    var microphone = false
    var accessibility = false
    var inputMonitoring = false
    /// What the Input Monitoring tri-state reads. Separate from the boolean `inputMonitoring` grant, as on the system.
    var inputMonitoringAnswer: TCCStatus = .notDetermined
    /// What the mic prompt does to the mic grant when it resolves.
    var microphoneGrantedByRequest = false
    /// The user has already answered "Don't Allow": the tri-state reads denied rather than notDetermined.
    var microphoneDenied = false
    private(set) var events: [String] = []

    func resetEvents() { events.removeAll() }

    func microphoneGranted() -> Bool {
        events.append("probe-microphone")
        return microphone
    }

    func microphoneStatus() -> TCCStatus {
        events.append("probe-microphoneStatus")
        if microphone { return .authorized }
        return microphoneDenied ? .denied : .notDetermined
    }

    func accessibilityGranted() -> Bool {
        events.append("probe-accessibility")
        return accessibility
    }

    func inputMonitoringGranted() -> Bool {
        events.append("probe-inputMonitoring")
        return inputMonitoring
    }

    func inputMonitoringStatus() -> TCCStatus {
        events.append("probe-inputMonitoringStatus")
        return inputMonitoringAnswer
    }

    func requestMicrophone() async -> Bool {
        events.append("request-microphone")
        microphone = microphoneGrantedByRequest
        // macOS answers a declined prompt with denied, and never prompts again.
        microphoneDenied = !microphoneGrantedByRequest
        return microphoneGrantedByRequest
    }

    func requestAccessibility() { events.append("request-accessibility") }
    func requestInputMonitoring() { events.append("request-inputMonitoring") }
}

/// Scripted notification authorization; `request` can flip the answer the way the user's click does.
final class FakeNotificationAuthorizer: NotificationAuthorizing {
    var current: NotificationAuthorization = .notDetermined
    /// What the prompt does to `current` when it resolves.
    var answerToRequest: NotificationAuthorization = .authorized
    private(set) var events: [String] = []

    func status() async -> NotificationAuthorization {
        events.append("status")
        return current
    }

    func request() async -> Bool {
        events.append("request")
        current = answerToRequest
        return answerToRequest == .authorized
    }
}

final class FakeNotifier: Notifier {
    private(set) var delivered: [(title: String, body: String)] = []
    /// When set, every delivery reports it through `onError`.
    var deliveryError: Error?

    func deliver(title: String, body: String, onError: @escaping @Sendable (Error) -> Void) {
        delivered.append((title, body))
        if let deliveryError { onError(deliveryError) }
    }
}

final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onModifierEvent: ((String) -> Void)?
    var installError: Error?
    var reinstallError: Error?
    /// Shared by every monitor a test builds, so the order of install and uninstall calls across swaps is assertable.
    var journal: Box<String>?
    var name = "monitor"
    private(set) var installCalls = 0
    private(set) var reinstallCalls = 0
    private(set) var uninstallCalls = 0
    private(set) var forgetCalls = 0

    func install() throws {
        installCalls += 1
        journal?.append("\(name):install")
        if let installError { throw installError }
    }

    func uninstall() {
        uninstallCalls += 1
        journal?.append("\(name):uninstall")
    }

    func reinstall() throws {
        reinstallCalls += 1
        if let reinstallError { throw reinstallError }
    }

    func forgetHeldKey() { forgetCalls += 1 }
}

/// A value shared with `@Sendable` closures (detached tasks, background queues) under a lock.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}

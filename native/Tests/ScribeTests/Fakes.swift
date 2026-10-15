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

    init(err: Error? = nil) {
        self.err = err
    }

    func paste(_ text: String) throws {
        if let err { throw err }
        pasted.append(text)
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

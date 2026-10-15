import Foundation

let VOICED = [Float](repeating: 0.1, count: 16000)
let SILENT = [Float](repeating: 0.0, count: 16000)

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
    private(set) var calls = 0
    // Audio as received, so tests can assert an enhancer ran before transcription.
    private(set) var received: [[Float]] = []

    init(text: String = "so um hello there world", err: Error? = nil) {
        self.text = text
        self.err = err
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        calls += 1
        received.append(pcm)
        if let err { throw err }
        return text
    }
}

final class FakeEnhancer: AudioEnhancer {
    let out: [Float]
    let err: Error?
    private(set) var calls = 0
    private(set) var received: [[Float]] = []

    init(out: [Float] = [Float](repeating: 0.5, count: 16000), err: Error? = nil) {
        self.out = out
        self.err = err
    }

    func enhance(_ pcm: [Float]) async throws -> [Float] {
        calls += 1
        received.append(pcm)
        if let err { throw err }
        return out
    }
}

final class FakeCleaner: CleanupBackend {
    let out: String
    let err: Error?
    let delay: Double
    private(set) var calls = 0
    // Inputs seen by clean(), so tests can assert what the model received.
    private(set) var received: [String] = []

    init(out: String = "hello there world", err: Error? = nil, delay: Double = 0.0) {
        self.out = out
        self.err = err
        self.delay = delay
    }

    func clean(_ text: String) async throws -> String {
        calls += 1
        received.append(text)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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

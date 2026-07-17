import Foundation

// Ported 1:1 from tests/fakes.py — used by PipelineTests.swift.

let VOICED = [Float](repeating: 0.1, count: 16000)
let SILENT = [Float](repeating: 0.0, count: 16000)

/// Generic test error for cases where the Python test used a bare
/// `RuntimeError(...)` rather than a specific domain error type.
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

    init(text: String = "so um hello there world", err: Error? = nil) {
        self.text = text
        self.err = err
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        calls += 1
        if let err { throw err }
        return text
    }
}

final class FakeCleaner: CleanupBackend {
    let out: String
    let err: Error?
    let delay: Double
    private(set) var calls = 0

    init(out: String = "hello there world", err: Error? = nil, delay: Double = 0.0) {
        self.out = out
        self.err = err
        self.delay = delay
    }

    func clean(_ text: String) async throws -> String {
        calls += 1
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

/// A mutable reference box so test closures (`onState`, `onNotice`,
/// `saveFailedAudio`) can accumulate values the test function reads back —
/// mirrors the plain `list.append` callbacks used in the Python test suite.
final class Box<T> {
    private(set) var value: [T] = []
    func append(_ v: T) { value.append(v) }
}

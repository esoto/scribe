import AVFoundation
import FluidAudio
import Foundation
import XCTest

/// The cleanup model under test, from `CLEANUP_MODEL` (gemma3 | gemma4 |
/// appleIntelligence; default gemma3). Must be an ENVIRONMENT variable with
/// the TEST_RUNNER_ prefix in front of xcodebuild
/// (`TEST_RUNNER_CLEANUP_MODEL=gemma4 xcodebuild …`); as an xcodebuild
/// argument it is silently ignored.
func cleanupSpecUnderTest() -> CleanupModelSpec {
    let raw = ProcessInfo.processInfo.environment["CLEANUP_MODEL"] ?? CleanupModelID.gemma3.rawValue
    guard let id = CleanupModelID(rawValue: raw) else { fatalError("unknown CLEANUP_MODEL=\(raw)") }
    return CleanupModelCatalog.spec(id)
}

/// Loaded once per test run and shared, so the golden/fidelity/guard
/// classes don't each hold their own multi-GB copy. Each test sets the
/// dictionary it needs first — never rely on another test's leftovers.
private let sharedCleanupBackend: Result<any CleanupModelBackend, Error> = Result {
    let spec = cleanupSpecUnderTest()
    if case .appleIntelligence = spec.kind {
        guard #available(macOS 26.0, *), AppleIntelligence.isAvailable else {
            throw XCTSkip("Apple Intelligence unavailable: \(AppleIntelligence.unavailableReason ?? "unknown")")
        }
        return AppleIntelligenceBackend()
    }
    return GemmaBackend(spec: spec)
}

func cleanupBackendUnderTest() throws -> any CleanupModelBackend {
    try sharedCleanupBackend.get()
}

/// Runs cases through `backend`, asserting every phrase (except cases that
/// list the model under test in `known_failures`, which are only printed).
/// Returns the number of passing cases.
func runGoldenCases(_ cases: [GoldenCase], backend: any CleanupModelBackend, tag: String) async throws -> Int {
    let modelID = cleanupSpecUnderTest().id.rawValue
    var passed = 0
    for testCase in cases {
        let t0 = Date()
        let raw = try await backend.clean(testCase.input)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let normalized = Gates.normalize(raw)
        let verdict = evaluateGoldenCase(testCase, rawOutput: raw)
        let known = testCase.knownFailures?.contains(modelID) ?? false
        passed += verdict.ok ? 1 : 0
        print("[\(tag)] \(verdict.ok ? "PASS" : known ? "KNOWN-FAIL" : "FAIL") [\(testCase.id)] \(ms) ms")
        if !verdict.ok { print("    out: \(normalized)") }
        guard !known else { continue }
        XCTAssertTrue(verdict.missing.isEmpty, "[\(testCase.id)] missing \(verdict.missing)\n  input:  \(testCase.input)\n  output: \(normalized)")
        XCTAssertTrue(verdict.present.isEmpty, "[\(testCase.id)] must not contain \(verdict.present)\n  input:  \(testCase.input)\n  output: \(normalized)")
    }
    print("[\(tag)] \(passed)/\(cases.count) passed")
    return passed
}

/// Loads a fixture WAV as the Float PCM the STT engines expect.
func loadPcm(_ name: String) throws -> [Float] {
    let url = repoRoot().appendingPathComponent("tests_models/fixtures/\(name)")
    let file = try AVAudioFile(forReading: url)
    let fmt = file.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return try AudioConverter().resampleBuffer(buf)
}

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

/// The edit twin of `runGoldenCases`: each case runs `edit(instruction:text:maxTokens:)` with the verb's own
/// instruction and the token budget the pipeline would give it, then the ONE pass rule (`evaluateEditCase`: gates
/// first, phrases second). A case that throws is a failed case, not an aborted run, so one MLX error does not cost
/// the other 27 results of a GPU pass. Returns the number of passing cases.
///
/// The output is printed for every failure and for every case that carries a `comment`: those cases exist to measure
/// a known gate hole, and the reading is in the text the model produced.
func runEditCases(_ cases: [EditCase], backend: any CleanupModelBackend, tag: String) async throws -> Int {
    let modelID = cleanupSpecUnderTest().id.rawValue
    var passed = 0
    for testCase in cases {
        guard let verb = testCase.editVerb else {
            XCTFail("[\(testCase.id)] unknown verb \(testCase.verb)")
            continue
        }
        let maxTokens = EditPrompt.maxTokens(verb: verb, inputTokens: testCase.text.count / 4)
        let known = testCase.knownFailures?.contains(modelID) ?? false
        let t0 = Date()
        let raw: String
        do {
            raw = try await backend.edit(instruction: verb.instruction, text: testCase.text, maxTokens: maxTokens)
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[\(tag)] \(known ? "KNOWN-FAIL" : "FAIL") [\(testCase.id)] \(ms) ms")
            print("    threw: \(error)")
            if !known { XCTFail("[\(testCase.id)] edit threw \(error)") }
            continue
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let result = evaluateEditCase(testCase, rawOutput: raw)
        let ok = editCasePassed(result)
        let shown = EditGates.normalize(raw, verb: verb)
        passed += ok ? 1 : 0
        print("[\(tag)] \(ok ? "PASS" : known ? "KNOWN-FAIL" : "FAIL") [\(testCase.id)] \(ms) ms")
        if !ok || testCase.comment != nil { print("    out: \(shown)") }
        if case .rejected(let reason) = result.verdict { print("    gate: rejected (\(reason.rawValue))") }
        guard !known else { continue }
        let context = "\n  input:  \(testCase.text)\n  output: \(shown)"
        if case .rejected(let reason) = result.verdict {
            XCTFail("[\(testCase.id)] gate rejected the output: \(reason.rawValue)\(context)")
        }
        XCTAssertTrue(result.missing.isEmpty, "[\(testCase.id)] missing \(result.missing)\(context)")
        XCTAssertTrue(result.present.isEmpty, "[\(testCase.id)] must not contain \(result.present)\(context)")
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

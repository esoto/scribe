import XCTest

/// Golden set with a populated dictionary. The terms are irrelevant to the inputs, so a failure means the injected wording interferes.
final class DictionaryGoldenEvalTests: XCTestCase {
    func testGoldenEvalSurvivesPopulatedDictionary() async throws {
        let backend = try cleanupBackendUnderTest()
        backend.setDictionary(DictionarySnapshot(
            pairs: [
                ReplacementPair(
                    original: "camel", replacement: "kamal",
                    addedAt: Date(timeIntervalSince1970: 0)),
                ReplacementPair(
                    original: "wisper", replacement: "Whisper",
                    addedAt: Date(timeIntervalSince1970: 0)),
            ],
            glossary: [
                "Hetzner", "KVCache", "MLX", "Parakeet", "XcodeGen", "kamal",
            ]))

        let golden = try loadGoldenSet("golden.json")

        let modelID = cleanupSpecUnderTest().id.rawValue
        var passed = 0
        var failures: [String] = []
        for testCase in golden.cases {
            let cleaned = try await backend.clean(testCase.input)
            let low = Gates.normalize(cleaned).lowercased()
            let verdict = evaluateGoldenCase(testCase, rawOutput: cleaned)
            let known = testCase.knownFailures?.contains(modelID) ?? false
            passed += verdict.ok ? 1 : 0
            print("[golden+dict] \(verdict.ok ? "PASS" : known ? "KNOWN-FAIL" : "FAIL") [\(testCase.id)]")
            if !verdict.ok { print("    out: \(low)") }
            guard !known else { continue }
            if !verdict.ok {
                failures.append(
                    "[\(testCase.id)] missing=\(verdict.missing) unexpected=\(verdict.present) output=\(low)")
            }
        }

        print("[golden+dict] \(passed)/\(golden.cases.count) passed")
        XCTAssertTrue(
            failures.isEmpty,
            "dictionary injection regressed cleanup:\n" + failures.joined(separator: "\n"))
    }
}

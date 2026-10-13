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

        var passed = 0
        var failures: [String] = []
        for testCase in golden.cases {
            let cleaned = try await backend.clean(testCase.input)
            let low = Gates.normalize(cleaned).lowercased()
            let missing = testCase.mustContain.filter { !low.contains($0.lowercased()) }
            let present = testCase.mustNotContain.filter { low.contains($0.lowercased()) }
            if missing.isEmpty && present.isEmpty {
                passed += 1
            } else {
                failures.append(
                    "[\(testCase.id)] missing=\(missing) unexpected=\(present) output=\(low)")
            }
        }

        print("[golden+dict] \(passed)/\(golden.cases.count) passed")
        XCTAssertEqual(
            passed, golden.cases.count,
            "dictionary injection regressed cleanup:\n" + failures.joined(separator: "\n"))
    }
}

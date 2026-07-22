import XCTest

private struct GoldenCase: Codable {
    let id: String
    let input: String
    let mustContain: [String]
    let mustNotContain: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case input
        case mustContain = "must_contain"
        case mustNotContain = "must_not_contain"
    }
}

private struct GoldenSet: Codable {
    let cases: [GoldenCase]
}

/// The golden set again, but with a POPULATED dictionary in the system
/// prompt. GoldenEvalTests only ever exercises the empty snapshot, where
/// the prompt is byte-identical to the validated base one — so it proves
/// nothing about the injected glossary/replacement wording. This is the
/// guard that the extra instructions don't degrade cleanup: the terms here
/// are deliberately irrelevant to the golden inputs, so a failure means the
/// wording itself is interfering (e.g. pulling the model toward
/// substitution or breaking the never-translate rule), not that a term was
/// legitimately applied.
final class DictionaryGoldenEvalTests: XCTestCase {
    static let gemma = GemmaBackend()

    func testGoldenEvalSurvivesPopulatedDictionary() async throws {
        let snapshot = DictionarySnapshot(
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
            ])
        Self.gemma.setDictionary(snapshot)

        let url = repoRoot().appendingPathComponent("tests_models/golden.json")
        let golden = try JSONDecoder().decode(GoldenSet.self, from: Data(contentsOf: url))

        var passed = 0
        var failures: [String] = []
        for testCase in golden.cases {
            let cleaned = try await Self.gemma.clean(testCase.input)
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

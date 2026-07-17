import XCTest

/// Codable mirror of `tests_models/golden.json` — the cleanup-prompt golden
/// set. Field names match the JSON via `CodingKeys` (snake_case on disk).
private struct GoldenCase: Codable {
    let id: String
    let input: String
    let mustContain: [String]
    let mustNotContain: [String]
    let comment: String?

    enum CodingKeys: String, CodingKey {
        case id
        case input
        case mustContain = "must_contain"
        case mustNotContain = "must_not_contain"
        case comment
    }
}

private struct GoldenSet: Codable {
    let description: String
    let cases: [GoldenCase]
}

/// **THE PARITY GATE.** Runs every case in `tests_models/golden.json` through
/// the real `GemmaBackend` — port of `tests_models/run_eval.py` /
/// `test_cleanup_gemma.py`. All 10 cases must pass before the native app can
/// replace the Python daily driver; a failure here means the native cleanup
/// pipeline (prompt, few-shots, or model) is not yet at parity with the
/// validated Python oracle.
///
/// `gemma` is a `static let` so the model loads once for the whole test
/// class rather than once per case.
final class GoldenEvalTests: XCTestCase {
    static let gemma = GemmaBackend()

    func testGoldenEvalAllCasesPass() async throws {
        let url = repoRoot().appendingPathComponent("tests_models/golden.json")
        let data = try Data(contentsOf: url)
        let golden = try JSONDecoder().decode(GoldenSet.self, from: data)

        var passed = 0
        for testCase in golden.cases {
            let t0 = Date()
            let cleaned = try await Self.gemma.clean(testCase.input)
            let normalized = Gates.normalize(cleaned)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let low = normalized.lowercased()

            let missing = testCase.mustContain.filter { !low.contains($0.lowercased()) }
            let present = testCase.mustNotContain.filter { low.contains($0.lowercased()) }
            let ok = missing.isEmpty && present.isEmpty
            passed += ok ? 1 : 0
            print("[golden] \(ok ? "PASS" : "FAIL") [\(testCase.id)] \(ms) ms")

            for phrase in testCase.mustContain {
                XCTAssertTrue(
                    low.contains(phrase.lowercased()),
                    """
                    [\(testCase.id)] expected output to contain "\(phrase)"
                      input:  \(testCase.input)
                      output: \(normalized)
                    """
                )
            }
            for phrase in testCase.mustNotContain {
                XCTAssertFalse(
                    low.contains(phrase.lowercased()),
                    """
                    [\(testCase.id)] expected output to NOT contain "\(phrase)"
                      input:  \(testCase.input)
                      output: \(normalized)
                    """
                )
            }
        }

        print("[golden] \(passed)/\(golden.cases.count) passed")
        XCTAssertEqual(passed, golden.cases.count, "golden eval score: \(passed)/\(golden.cases.count) — see per-case failures above")
    }
}

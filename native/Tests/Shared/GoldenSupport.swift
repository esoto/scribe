import Foundation

/// Locates the repo root from this file's on-disk path (same depth as the
/// old ModelTestSupport copy: native/Tests/<dir>/File.swift).
func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// Codable mirror of `tests_models/golden.json` / `injection_guard.json`
/// (snake_case on disk). The ONE copy — the test files used to carry three.
struct GoldenCase: Codable {
    let id: String
    let input: String
    let mustContain: [String]
    let mustNotContain: [String]
    let comment: String?
    /// Model ids allowed to fail this case (reported, not asserted). Only
    /// ever set with the user's sign-off; the default model may never be listed.
    let knownFailures: [String]?

    enum CodingKeys: String, CodingKey {
        case id, input, comment
        case mustContain = "must_contain"
        case mustNotContain = "must_not_contain"
        case knownFailures = "known_failures"
    }
}

struct GoldenSet: Codable {
    let description: String?
    let cases: [GoldenCase]
}

func loadGoldenSet(_ file: String) throws -> GoldenSet {
    let data = try Data(contentsOf: repoRoot().appendingPathComponent("tests_models/\(file)"))
    return try JSONDecoder().decode(GoldenSet.self, from: data)
}

struct GoldenVerdict: Equatable {
    let missing: [String]
    let present: [String]
    var ok: Bool { missing.isEmpty && present.isEmpty }
}

/// The ONE pass/fail rule for a golden or guard case. Pure, so `ScribeTests`
/// can prove it fails when it should.
///
/// `Gates.normalize` collapses ALL whitespace, so a `must_not_contain` phrase
/// that contains a newline ("\n\n", "\n- ") could never match normalized text
/// and the assertion would be vacuous. Those phrases are checked against the
/// RAW output; every other phrase (and all `must_contain`) against the
/// normalized, lowercased output.
func evaluateGoldenCase(_ testCase: GoldenCase, rawOutput: String) -> GoldenVerdict {
    let normalizedLow = Gates.normalize(rawOutput).lowercased()
    let rawLow = rawOutput.lowercased()
    let missing = testCase.mustContain.filter { !normalizedLow.contains($0.lowercased()) }
    let present = testCase.mustNotContain.filter { phrase in
        let p = phrase.lowercased()
        return p.contains("\n") ? rawLow.contains(p) : normalizedLow.contains(p)
    }
    return GoldenVerdict(missing: missing, present: present)
}

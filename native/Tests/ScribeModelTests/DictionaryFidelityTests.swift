import XCTest

/// Checks that cleanup never drops a word that appears in the input and dictionary.
final class DictionaryFidelityTests: XCTestCase {
    static let gemma = GemmaBackend()

    private static func pair(_ o: String, _ r: String) -> ReplacementPair {
        ReplacementPair(original: o, replacement: r, addedAt: Date(timeIntervalSince1970: 0))
    }

    private struct Case {
        let condition: String
        let snapshot: DictionarySnapshot
        let input: String
        let mustContain: [String]
    }

    private static let pairs = [pair("camel", "kamal"), pair("headsner", "hetzner")]
    // Must not include a pair's replacement; naming a term in both lists made the model drop it.
    private static let learned = ["Postgres", "hetzner"]

    private static let cases: [Case] = [
        Case(
            condition: "pairs", snapshot: DictionarySnapshot(pairs: pairs, glossary: []),
            input: "so um deploy with camel to production tonight",
            mustContain: ["kamal", "production", "tonight"]),
        Case(
            condition: "pairs", snapshot: DictionarySnapshot(pairs: pairs, glossary: []),
            input: "so um deploy with kamal to hetzner tonight",
            mustContain: ["kamal", "hetzner", "tonight"]),
        Case(
            condition: "pairs", snapshot: DictionarySnapshot(pairs: pairs, glossary: []),
            input: "so um deploy with camel to hetzner tonight",
            mustContain: ["kamal", "hetzner", "tonight"]),
        Case(
            condition: "learned", snapshot: DictionarySnapshot(pairs: [], glossary: learned),
            input: "so um deploy with kamal to hetzner tonight",
            mustContain: ["kamal", "hetzner", "tonight"]),
        Case(
            condition: "learned", snapshot: DictionarySnapshot(pairs: [], glossary: learned),
            input: "um the kamal deploy finished at noon",
            mustContain: ["kamal", "deploy", "noon"]),
        Case(
            condition: "both", snapshot: DictionarySnapshot(pairs: pairs, glossary: learned),
            input: "so um deploy with kamal to hetzner tonight",
            mustContain: ["kamal", "hetzner", "tonight"]),
        Case(
            condition: "both", snapshot: DictionarySnapshot(pairs: pairs, glossary: learned),
            input: "so um deploy with camel to hetzner tonight",
            mustContain: ["kamal", "hetzner", "tonight"]),
        Case(
            condition: "both", snapshot: DictionarySnapshot(pairs: pairs, glossary: learned),
            input: "so um restore the camel backup from postgres tonight",
            mustContain: ["kamal", "postgres", "backup"]),
        Case(
            condition: "both", snapshot: DictionarySnapshot(pairs: pairs, glossary: learned),
            input: "so um send the report on monday no wait tuesday morning",
            mustContain: ["report", "tuesday", "morning"]),
    ]

    private func run(condition: String) async throws -> [String] {
        var failures: [String] = []
        for testCase in Self.cases where testCase.condition == condition {
            Self.gemma.setDictionary(testCase.snapshot)
            // Mirrors DictationPipeline.process: pairs are applied around the model.
            let pairs = testCase.snapshot.pairs
            let transcript = TermReplacer.apply(pairs, to: testCase.input)
            let out = TermReplacer.apply(pairs, to: try await Self.gemma.clean(transcript))
            let low = out.lowercased()
            let missing = testCase.mustContain.filter { !low.contains($0.lowercased()) }
            print("[fidelity][\(condition)] \(missing.isEmpty ? "PASS" : "FAIL lost=\(missing)")")
            print("    in : \(testCase.input)")
            print("    out: \(out)")
            if !missing.isEmpty {
                failures.append("lost \(missing) — \"\(testCase.input)\" -> \"\(out)\"")
            }
        }
        return failures
    }

    /// Release blocker: the shipping config (learning off) must never drop a word.
    func testReplacementPairsNeverDropWords() async throws {
        let failures = try await run(condition: "pairs")
        XCTAssertTrue(failures.isEmpty, "pairs dropped content:\n" + failures.joined(separator: "\n"))
    }

    /// Pins a known defect: the learned-vocabulary prompt section makes Gemma drop words.
    /// If this starts failing, the defect is fixed; re-check `dictionaryLearningEnabled` and delete this test.
    func testLearnedVocabularyStillDropsWords_knownDefect() async throws {
        let failures = try await run(condition: "learned") + (try await run(condition: "both"))
        XCTAssertFalse(
            failures.isEmpty,
            """
            The learned-vocabulary section no longer drops words — the known \
            defect appears to be fixed. Re-check the default for \
            dictionaryLearningEnabled and remove this test.
            """)
    }
}

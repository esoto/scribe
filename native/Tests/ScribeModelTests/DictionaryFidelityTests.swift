import XCTest

/// The test that should have existed before any dictionary wording shipped.
///
/// `DictionaryGoldenEvalTests` runs the golden set with a populated
/// dictionary whose terms are deliberately IRRELEVANT to the inputs — it
/// proves unrelated vocabulary doesn't disturb unrelated cleanup, and
/// nothing more. It cannot catch the failure that matters: a sentence that
/// actually CONTAINS dictionary terms coming back with one of them deleted.
///
/// That failure is the worst one this app has — scribe's contract is that
/// you never lose words — so every case here asserts on content
/// preservation first and correction second.
final class DictionaryFidelityTests: XCTestCase {
    static let gemma = GemmaBackend()

    private static func pair(_ o: String, _ r: String) -> ReplacementPair {
        ReplacementPair(original: o, replacement: r, addedAt: Date(timeIntervalSince1970: 0))
    }

    private struct Case {
        let condition: String
        let snapshot: DictionarySnapshot
        let input: String
        /// Substrings the output MUST retain, case-insensitively.
        let mustContain: [String]
    }

    private static let pairs = [pair("camel", "kamal"), pair("headsner", "hetzner")]
    /// Auto-learned vocabulary. Deliberately does NOT contain a pair's
    /// replacement: seeding those in here was tried and reverted because
    /// naming a term in both lists made the model drop it (see
    /// `UserDictionary.computeSnapshotLocked`).
    private static let learned = ["Postgres", "hetzner"]

    private static let cases: [Case] = [
        // Manual pairs: the mishearing is corrected, the rest survives.
        Case(
            condition: "pairs", snapshot: DictionarySnapshot(pairs: pairs, glossary: []),
            input: "so um deploy with camel to production tonight",
            mustContain: ["kamal", "production", "tonight"]),
        // The critical one: the speaker got BOTH words right. Cleanup must
        // not drop either just because they appear in the dictionary.
        Case(
            condition: "pairs", snapshot: DictionarySnapshot(pairs: pairs, glossary: []),
            input: "so um deploy with kamal to hetzner tonight",
            mustContain: ["kamal", "hetzner", "tonight"]),
        // Same input as the "both" case below, minus the vocabulary list —
        // isolates which section is responsible when it fails.
        Case(
            condition: "pairs", snapshot: DictionarySnapshot(pairs: pairs, glossary: []),
            input: "so um deploy with camel to hetzner tonight",
            mustContain: ["kamal", "hetzner", "tonight"]),
        // Learned vocabulary only (what auto-learning produces).
        Case(
            condition: "learned", snapshot: DictionarySnapshot(pairs: [], glossary: learned),
            input: "so um deploy with kamal to hetzner tonight",
            mustContain: ["kamal", "hetzner", "tonight"]),
        Case(
            condition: "learned", snapshot: DictionarySnapshot(pairs: [], glossary: learned),
            input: "um the kamal deploy finished at noon",
            mustContain: ["kamal", "deploy", "noon"]),
        // Both coexist in real use: learned terms plus manual pairs, with
        // one of each in the same sentence.
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
        // A dictionary must never disturb a sentence that has nothing to
        // do with it.
        Case(
            condition: "both", snapshot: DictionarySnapshot(pairs: pairs, glossary: learned),
            input: "so um send the report on monday no wait tuesday morning",
            mustContain: ["report", "tuesday", "morning"]),
    ]

    /// Runs the cases for one condition and returns the ones that lost words.
    private func run(condition: String) async throws -> [String] {
        var failures: [String] = []
        for testCase in Self.cases where testCase.condition == condition {
            Self.gemma.setDictionary(testCase.snapshot)
            let out = try await Self.gemma.clean(testCase.input)
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

    /// Manual replacement pairs must never cost a word. This is the shipping
    /// configuration (`dictionaryLearningEnabled` defaults to false), so a
    /// failure here is a release blocker.
    func testReplacementPairsNeverDropWords() async throws {
        let failures = try await run(condition: "pairs")
        XCTAssertTrue(failures.isEmpty, "pairs dropped content:\n" + failures.joined(separator: "\n"))
    }

    /// Pins a KNOWN DEFECT, deliberately, so it can't be forgotten: adding the
    /// learned-vocabulary section to the prompt makes Gemma drop words from
    /// the sentence — including words the list never mentions. Isolated with
    /// a vocabulary of just "Postgres" against a sentence containing neither
    /// that word nor anything like it; the same sentence is clean under
    /// `pairs` alone.
    ///
    /// This is why auto-learning ships OFF by default. If this test starts
    /// FAILING, the wording experiment succeeded — re-evaluate the default in
    /// `AppSettings.dictionaryLearningEnabled` and delete this test.
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

import XCTest

final class BiasVocabularyTests: XCTestCase {
    private func pair(_ o: String, _ r: String) -> ReplacementPair {
        ReplacementPair(original: o, replacement: r, addedAt: Date(timeIntervalSince1970: 0))
    }
    private func gloss(_ t: String) -> GlossaryEntry {
        GlossaryEntry(term: t, count: 3, firstSeen: Date(timeIntervalSince1970: 0),
                      lastSeen: Date(timeIntervalSince1970: 0))
    }

    func testPairBecomesTermWithOriginalAsAlias() {
        let out = BiasVocabularyBuilder.build(
            pairs: [pair("camel", "kamal")], glossary: [], includeCuratedPack: false)
        XCTAssertEqual(out, [BiasTerm(text: "kamal", aliases: ["camel"])])
    }

    func testGlossaryBecomesAliaslessTerm() {
        let out = BiasVocabularyBuilder.build(
            pairs: [], glossary: [gloss("Parakeet")], includeCuratedPack: false)
        XCTAssertEqual(out, [BiasTerm(text: "Parakeet", aliases: [])])
    }

    func testCuratedPackMergedOnlyWhenRequested() {
        let off = BiasVocabularyBuilder.build(pairs: [], glossary: [], includeCuratedPack: false)
        XCTAssertTrue(off.isEmpty)
        let on = BiasVocabularyBuilder.build(pairs: [], glossary: [], includeCuratedPack: true)
        XCTAssertTrue(on.contains { $0.text == "Kubernetes" })
        XCTAssertTrue(on.contains { $0.text == "Postgres" })
    }

    func testEmptyInputsAndPackOffYieldEmpty() {
        // Underpins the no-regression guarantee: nothing to bias → identity.
        XCTAssertTrue(
            BiasVocabularyBuilder.build(pairs: [], glossary: [], includeCuratedPack: false).isEmpty)
    }

    func testCaseInsensitiveDedupUnionsAliases() {
        // Same canonical from two pairs with different manglings → one term,
        // both manglings as aliases.
        let out = BiasVocabularyBuilder.build(
            pairs: [pair("camel", "Kamal"), pair("camal", "kamal")],
            glossary: [], includeCuratedPack: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Kamal")  // first spelling wins
        XCTAssertEqual(Set(out[0].aliases.map { $0.lowercased() }), ["camel", "camal"])
    }

    func testGlossaryMatchingAPairTargetDoesNotDuplicate() {
        let out = BiasVocabularyBuilder.build(
            pairs: [pair("camel", "kamal")], glossary: [gloss("Kamal")],
            includeCuratedPack: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "kamal")           // pair seen first
        XCTAssertEqual(out[0].aliases, ["camel"])      // keeps the pair's alias
    }

    func testSubMinLengthAndEmptyCanonicalsDropped() {
        // A short replacement ("PR", 2 chars) and a glossary term that
        // sanitizes empty are both dropped; a valid canonical with an
        // unusable original survives with no alias.
        let out = BiasVocabularyBuilder.build(
            pairs: [pair("heard", "PR"), pair("<>", "kamal")],
            glossary: [gloss("ok"), gloss("\"\"")],
            includeCuratedPack: false)
        XCTAssertEqual(out, [BiasTerm(text: "kamal", aliases: [])])
    }

    func testAliasEqualToCanonicalIsDropped() {
        let out = BiasVocabularyBuilder.build(
            pairs: [pair("Kamal", "kamal")], glossary: [], includeCuratedPack: false)
        XCTAssertEqual(out, [BiasTerm(text: "kamal", aliases: [])])
    }
}

final class EngineeringVocabularyTests: XCTestCase {
    func testPackIsWellFormed() {
        let terms = EngineeringVocabulary.terms
        XCTAssertFalse(terms.isEmpty)
        // No case-insensitive duplicates.
        let lowered = terms.map { $0.lowercased() }
        XCTAssertEqual(lowered.count, Set(lowered).count, "duplicate curated terms")
        for term in terms {
            XCTAssertGreaterThanOrEqual(term.count, 3, "\(term) is below the spotter's min length")
            // Every entry survives prompt sanitization unchanged (no control chars / markup).
            XCTAssertEqual(CleanupPrompt.sanitizeTerm(term), term, "\(term) is not sanitize-stable")
        }
    }
}

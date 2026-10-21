import XCTest

final class TermReplacerTests: XCTestCase {
    private func pair(_ o: String, _ r: String) -> ReplacementPair {
        ReplacementPair(original: o, replacement: r, addedAt: Date(timeIntervalSince1970: 0))
    }

    private var pairs: [ReplacementPair] {
        [pair("camel", "kamal"), pair("headsner", "hetzner")]
    }

    func testReplacesWholeWordsCaseInsensitively() {
        XCTAssertEqual(
            TermReplacer.apply(pairs, to: "deploy with camel tonight"),
            "deploy with kamal tonight")
        XCTAssertEqual(
            TermReplacer.apply(pairs, to: "Camel is ready"), "kamal is ready")
        XCTAssertEqual(
            TermReplacer.apply(pairs, to: "CAMEL is ready"), "kamal is ready")
    }

    func testPreservesAttachedPunctuation() {
        XCTAssertEqual(
            TermReplacer.apply(pairs, to: "we use camel, obviously"),
            "we use kamal, obviously")
        XCTAssertEqual(TermReplacer.apply(pairs, to: "(camel)"), "(kamal)")
        XCTAssertEqual(TermReplacer.apply(pairs, to: "camel."), "kamal.")
        XCTAssertEqual(TermReplacer.apply(pairs, to: "\u{201C}camel\u{201D}"), "\u{201C}kamal\u{201D}")
    }

    func testNeverRewritesInsideALongerWord() {
        XCTAssertEqual(TermReplacer.apply(pairs, to: "camelCase naming"), "camelCase naming")
        XCTAssertEqual(TermReplacer.apply(pairs, to: "camels grazing"), "camels grazing")
        XCTAssertEqual(TermReplacer.apply(pairs, to: "the camel-case rule"), "the camel-case rule")
    }

    func testMultipleTermsInOneSentence() {
        XCTAssertEqual(
            TermReplacer.apply(pairs, to: "deploy with camel to headsner tonight"),
            "deploy with kamal to hetzner tonight")
    }

    func testReplacementIsUsedVerbatimIncludingCase() {
        // Replacement is literal output, so "kamal" stays lowercase at sentence start.
        XCTAssertEqual(TermReplacer.apply(pairs, to: "Camel deploys nightly"), "kamal deploys nightly")
    }

    func testPunctuationAndMarkupSurviveInReplacements() {
        // Pairs are pasted text, so markup stripped from prompt glossary must survive.
        let markup = [pair("div tag", "<div>"), pair("quote", "\"")]
        XCTAssertEqual(TermReplacer.apply(markup, to: "add a quote here"), "add a \" here")
    }

    func testNoOpCases() {
        XCTAssertEqual(TermReplacer.apply([], to: "deploy with camel"), "deploy with camel")
        XCTAssertEqual(TermReplacer.apply(pairs, to: ""), "")
        XCTAssertEqual(TermReplacer.apply(pairs, to: "nothing to do here"), "nothing to do here")
        XCTAssertEqual(
            TermReplacer.apply([pair("  ", "x")], to: "deploy with camel"), "deploy with camel")
    }

    func testMultiWordOriginalMatchesAsAPhrase() {
        let p = [pair("memory service", "memory_service")]
        XCTAssertEqual(
            TermReplacer.apply(p, to: "deploy the memory service tonight"),
            "deploy the memory_service tonight")
        XCTAssertEqual(TermReplacer.apply(p, to: "Memory Service!"), "memory_service!")
    }

    func testLongestMatchWins() {
        let p = [pair("memory", "RAM"), pair("memory service", "memory_service")]
        XCTAssertEqual(
            TermReplacer.apply(p, to: "the memory service uses memory"),
            "the memory_service uses RAM")
    }

    func testPhraseKeepsEdgePunctuationOnly() {
        let p = [pair("cuber netties", "Kubernetes")]
        XCTAssertEqual(TermReplacer.apply(p, to: "(cuber netties)"), "(Kubernetes)")
        XCTAssertEqual(TermReplacer.apply(p, to: "cuber, netties"), "cuber, netties")
    }

    func testOriginalWhitespaceIsNormalised() {
        let p = [pair("  cuber   netties ", "Kubernetes")]
        XCTAssertEqual(TermReplacer.apply(p, to: "run cuber netties now"), "run Kubernetes now")
    }

    func testSpanishAccentsMatchCaseInsensitively() {
        let p = [pair("méxico city", "Ciudad de México")]
        XCTAssertEqual(TermReplacer.apply(p, to: "fly to México City"), "fly to Ciudad de México")
    }

    func testTrailingPunctuationIsDroppedOnlyWhenTheMatchEndsTheText() {
        let block: [(original: String, replacement: String, keepTrailing: Bool)] = [
            ("my address", "12 Elm St\nSpringfield", false)
        ]
        XCTAssertEqual(
            TermReplacer.apply(entries: block, to: "Send it to my address."), "Send it to 12 Elm St\nSpringfield")
        // Mid-text the period belongs to the sentence, so it stays.
        XCTAssertEqual(
            TermReplacer.apply(entries: block, to: "Send it to my address. Thanks."),
            "Send it to 12 Elm St\nSpringfield. Thanks.")
        // Closing brackets and quotes are not sentence punctuation, even at the end of the text.
        XCTAssertEqual(TermReplacer.apply(entries: block, to: "(my address)"), "(12 Elm St\nSpringfield)")
        XCTAssertEqual(
            TermReplacer.apply(entries: block, to: "\u{201C}my address\u{201D}."),
            "\u{201C}12 Elm St\nSpringfield\u{201D}")
        // Entries that keep their trailing punctuation, and the plain pair form every dictionary pair uses, keep it.
        let keeper: [(original: String, replacement: String, keepTrailing: Bool)] = [
            ("my address", "12 Elm St\nSpringfield", true)
        ]
        XCTAssertEqual(TermReplacer.apply(entries: keeper, to: "my address."), "12 Elm St\nSpringfield.")
        XCTAssertEqual(
            TermReplacer.apply([pair("my address", "12 Elm St\nSpringfield")], to: "my address."),
            "12 Elm St\nSpringfield.")
    }
}

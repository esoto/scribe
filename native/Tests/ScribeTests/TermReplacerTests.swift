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
        // The case that made the prompt-based version delete a word.
        XCTAssertEqual(
            TermReplacer.apply(pairs, to: "deploy with camel to headsner tonight"),
            "deploy with kamal to hetzner tonight")
    }

    func testReplacementIsUsedVerbatimIncludingCase() {
        // The pair's right-hand side is literal output — "kamal" stays
        // lowercase even at the start of a sentence.
        XCTAssertEqual(TermReplacer.apply(pairs, to: "Camel deploys nightly"), "kamal deploys nightly")
    }

    func testPunctuationAndMarkupSurviveInReplacements() {
        // Pairs are pasted text, not prompt text, so characters that were
        // stripped when they went into the system prompt must survive here.
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
}

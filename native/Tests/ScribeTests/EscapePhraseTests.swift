import XCTest

final class EscapePhraseTests: XCTestCase {
    private func resolve(_ said: String) -> (escaped: Set<Int>, dropped: Set<Int>) {
        let folded = said.split(separator: " ").map { VoiceCommand.fold(String($0)) }
        return EscapePhrase.resolve(folded: folded)
    }

    func testTheEscapeBeforeABreakPhraseIsDroppedAndThePhraseIsEscaped() {
        let r = resolve("the words new line")
        XCTAssertEqual(r.dropped, [0, 1])
        XCTAssertEqual(r.escaped, [2, 3])
    }

    func testTheSpanishEscapeWorksOnSpanishPhrases() {
        let r = resolve("las palabras nueva linea")
        XCTAssertEqual(r.dropped, [0, 1])
        XCTAssertEqual(r.escaped, [2, 3])
    }

    func testTheEscapeAlsoCoversAWholeUtteranceCommandPhrase() {
        let r = resolve("the words enter")
        XCTAssertEqual(r.dropped, [0, 1])
        XCTAssertEqual(r.escaped, [2])
        let undo = resolve("the words scratch that")
        XCTAssertEqual(undo.dropped, [0, 1])
        XCTAssertEqual(undo.escaped, [2, 3])
    }

    func testTheLongestPhraseIsEscapedSoNoTailIsLeftToSplit() {
        let r = resolve("the words new line break")
        XCTAssertEqual(r.escaped, [2, 3, 4])
        let spanish = resolve("las palabras salto de linea")
        XCTAssertEqual(spanish.escaped, [2, 3, 4])
    }

    func testAnEscapeNotFollowedByAPhraseChangesNothing() {
        for said in ["the words matter", "the words", "las palabras", "the words are new", "palabras las nueva"] {
            let r = resolve(said)
            XCTAssertTrue(r.dropped.isEmpty, said)
            XCTAssertTrue(r.escaped.isEmpty, said)
        }
    }

    func testAPhraseWithoutAnEscapeChangesNothing() {
        let r = resolve("add a new line here")
        XCTAssertTrue(r.dropped.isEmpty)
        XCTAssertTrue(r.escaped.isEmpty)
    }

    func testOnlyThePhraseRightAfterTheEscapeIsEscaped() {
        let r = resolve("the words new line new line")
        XCTAssertEqual(r.dropped, [0, 1])
        XCTAssertEqual(r.escaped, [2, 3])
    }

    func testEachEscapeInAnUtteranceIsResolved() {
        let r = resolve("a the words new line b las palabras nuevo parrafo c")
        XCTAssertEqual(r.dropped, [1, 2, 6, 7])
        XCTAssertEqual(r.escaped, [3, 4, 8, 9])
    }

    func testAnEscapeBeforeAnEscapeDoesNotConsumeItsOwnWords() {
        // The first "the words" is followed by another escape, not a phrase, so it stays text.
        let r = resolve("the words the words new line")
        XCTAssertEqual(r.dropped, [2, 3])
        XCTAssertEqual(r.escaped, [4, 5])
    }

    func testAnEscapeAtTheEndOfTheUtteranceHasNothingToEscape() {
        let r = resolve("add a new line the words")
        XCTAssertTrue(r.dropped.isEmpty)
        XCTAssertTrue(r.escaped.isEmpty)
    }

    func testEveryPhraseInBothTablesCanBeEscaped() {
        let phrases = Set(BreakSplitter.phrases.keys).union(VoiceCommand.phrases.keys.map { $0.split(separator: " ").map(String.init) })
        XCTAssertGreaterThan(phrases.count, 20)
        for escape in EscapePhrase.phrases {
            for phrase in phrases {
                let r = EscapePhrase.resolve(folded: escape + phrase)
                XCTAssertEqual(r.dropped, Set(0..<escape.count), "\(escape + phrase)")
                XCTAssertEqual(r.escaped, Set(escape.count..<(escape.count + phrase.count)), "\(escape + phrase)")
            }
        }
    }

    func testEscapePhrasesAreFoldedAndCoverEnglishAndSpanish() {
        XCTAssertEqual(EscapePhrase.phrases, [["the", "words"], ["las", "palabras"]])
        for word in EscapePhrase.phrases.flatMap({ $0 }) {
            XCTAssertEqual(VoiceCommand.fold(word), word, "a table entry must already be in folded form to ever match")
        }
    }

    func testAsrCasingAndPunctuationDoNotHideTheEscape() {
        let folded = "The Words, New line.".split(separator: " ").map { VoiceCommand.fold(String($0)) }
        let r = EscapePhrase.resolve(folded: folded)
        XCTAssertEqual(r.dropped, [0, 1])
        XCTAssertEqual(r.escaped, [2, 3])
    }
}

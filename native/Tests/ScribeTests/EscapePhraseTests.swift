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

    func testACommandPhraseInsideASentenceIsNotEscaped() {
        // Return and undo only fire on a whole utterance, so inside a sentence there is nothing to escape and the
        // words must survive: "type the words enter in the box" is ordinary text.
        for said in [
            "type the words enter in the box", "a the words scratch that b", "di las palabras enviar", "x the words enter",
        ] {
            let r = resolve(said)
            XCTAssertTrue(r.dropped.isEmpty, said)
            XCTAssertTrue(r.escaped.isEmpty, said)
        }
    }

    func testACommandPhraseIsEscapedOnlyWhenItIsAllThatWasSaid() {
        // Starting the utterance is not enough: "the words enter now" is not a whole-utterance command either way.
        for said in ["the words enter now", "the words scratch that please", "las palabras enviar ahora"] {
            let r = resolve(said)
            XCTAssertTrue(r.dropped.isEmpty, said)
            XCTAssertTrue(r.escaped.isEmpty, said)
        }
        let spanish = resolve("las palabras enviar")
        XCTAssertEqual(spanish.dropped, [0, 1])
        XCTAssertEqual(spanish.escaped, [2])
    }

    func testStrayPunctuationAroundAWholeUtteranceCommandDoesNotHideIt() {
        // A lone dash folds to an empty token; VoiceCommand.match ignores it, so the escape must too.
        let r = EscapePhrase.resolve(folded: ["", "the", "words", "enter", ""])
        XCTAssertEqual(r.dropped, [1, 2])
        XCTAssertEqual(r.escaped, [3])
    }

    func testABreakPhraseIsEscapedAnywhereInTheUtterance() {
        let mid = resolve("type the words new line in the box")
        XCTAssertEqual(mid.dropped, [1, 2])
        XCTAssertEqual(mid.escaped, [3, 4])
        let start = resolve("the words new line in the box")
        XCTAssertEqual(start.dropped, [0, 1])
        XCTAssertEqual(start.escaped, [2, 3])
    }

    func testBreakPhrasesAreEscapedMidSentenceAndCommandOnlyPhrasesAreNot() {
        let breaks = Set(BreakSplitter.phrases.keys)
        let commandOnly = VoiceCommand.phraseTokens.subtracting(breaks)
        XCTAssertFalse(commandOnly.isEmpty)
        for escape in EscapePhrase.phrases {
            for phrase in breaks {
                let r = EscapePhrase.resolve(folded: ["a"] + escape + phrase + ["b"])
                XCTAssertEqual(r.escaped.count, phrase.count, "\(phrase)")
            }
            for phrase in commandOnly {
                let r = EscapePhrase.resolve(folded: ["a"] + escape + phrase + ["b"])
                XCTAssertTrue(r.escaped.isEmpty && r.dropped.isEmpty, "\(phrase)")
            }
        }
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

    func testASentenceEndOnTheEscapeBlocksItInsideAnUtteranceButNotAtItsStart() {
        // "I can't find the words. New line." — the full stop closes a sentence, so nothing is escaped or dropped.
        let blocked = EscapePhrase.resolve(folded: ["a", "the", "words", "new", "line"], sentenceEnds: [2])
        XCTAssertTrue(blocked.dropped.isEmpty)
        XCTAssertTrue(blocked.escaped.isEmpty)
        let spanish = EscapePhrase.resolve(folded: ["a", "las", "palabras", "nueva", "linea"], sentenceEnds: [2])
        XCTAssertTrue(spanish.dropped.isEmpty && spanish.escaped.isEmpty)
        // An escape that opens the utterance has no earlier sentence to close, so "The words. New line." still works.
        let opening = EscapePhrase.resolve(folded: ["the", "words", "new", "line"], sentenceEnds: [1])
        XCTAssertEqual(opening.dropped, [0, 1])
        XCTAssertEqual(opening.escaped, [2, 3])
        // Only a sentence end on the escape's own last word blocks it.
        let elsewhere = EscapePhrase.resolve(folded: ["a", "the", "words", "new", "line"], sentenceEnds: [0, 4])
        XCTAssertEqual(elsewhere.dropped, [1, 2])
        XCTAssertEqual(elsewhere.escaped, [3, 4])
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

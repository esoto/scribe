import XCTest

final class BreakSplitterTests: XCTestCase {
    private func seg(_ text: String, _ brk: Break? = nil) -> Segment { Segment(text: text, breakAfter: brk) }

    func testNoBreakPhraseIsOneSegment() {
        XCTAssertEqual(BreakSplitter.split("so um hello there world"), [seg("so um hello there world")])
        XCTAssertEqual(BreakSplitter.split(""), [])
    }

    func testSplitsAtNewLineAndNewParagraphWithAsrPunctuation() {
        XCTAssertEqual(
            BreakSplitter.split("first line, new line, second line. New paragraph. Third."),
            [seg("first line", .line), seg("second line.", .paragraph), seg("Third.")])
    }

    func testADanglingCommaOrSemicolonBeforeABreakIsDroppedButMeaningfulMarksStay() {
        XCTAssertEqual(BreakSplitter.split("buy milk, new line, buy eggs"), [seg("buy milk", .line), seg("buy eggs")])
        XCTAssertEqual(BreakSplitter.split("one; new line two"), [seg("one", .line), seg("two")])
        XCTAssertEqual(BreakSplitter.split("Agenda: new line item one"), [seg("Agenda:", .line), seg("item one")])
        XCTAssertEqual(BreakSplitter.split("really? new line yes"), [seg("really?", .line), seg("yes")])
        XCTAssertEqual(BreakSplitter.split("wait... new line yes"), [seg("wait...", .line), seg("yes")])
    }

    func testPunctuationStandingAloneAtABreakIsDropped() {
        XCTAssertEqual(
            BreakSplitter.split("first line — new line — second"), [seg("first line", .line), seg("second")])
        XCTAssertEqual(BreakSplitter.split("first , new line , second"), [seg("first", .line), seg("second")])
        XCTAssertEqual(BreakSplitter.split("— new line hello"), [seg("hello")])
        XCTAssertEqual(BreakSplitter.split("hello new line — new line world"), [seg("hello", .line), seg("world")])
        XCTAssertEqual(BreakSplitter.split("what ? new line yes"), [seg("what ?", .line), seg("yes")], "a lone ? means something")
    }

    func testPunctuationAtTheEndOfTheUtteranceIsKept() {
        XCTAssertEqual(BreakSplitter.split("first new line second,"), [seg("first", .line), seg("second,")])
    }

    func testSpanishPhrasesWithAndWithoutAccents() {
        XCTAssertEqual(
            BreakSplitter.split("hola nueva línea adiós salto de linea fin nuevo párrafo ya"),
            [seg("hola", .line), seg("adiós", .line), seg("fin", .paragraph), seg("ya")])
    }

    func testBreaksAtTheEdgesAreDroppedAndDoublesCollapse() {
        XCTAssertEqual(BreakSplitter.split("new line hello"), [seg("hello")])
        XCTAssertEqual(BreakSplitter.split("hello new line"), [seg("hello")])
        XCTAssertEqual(BreakSplitter.split("hello new line new line world"), [seg("hello", .line), seg("world")])
        XCTAssertEqual(
            BreakSplitter.split("hello new line new paragraph world"), [seg("hello", .paragraph), seg("world")])
        XCTAssertEqual(BreakSplitter.split("new paragraph"), [])
        XCTAssertEqual(BreakSplitter.split("New line. New line."), [])
        XCTAssertEqual(BreakSplitter.split("new line new paragraph"), [])
    }

    func testLargestBreakIsTheParagraphIfAnyElseTheLine() {
        XCTAssertEqual(BreakSplitter.largestBreak(in: "New line. New line."), .line)
        XCTAssertEqual(BreakSplitter.largestBreak(in: "new line new paragraph"), .paragraph)
        XCTAssertEqual(BreakSplitter.largestBreak(in: "nuevo párrafo nueva línea"), .paragraph)
        XCTAssertEqual(BreakSplitter.largestBreak(in: "hello new line world"), .line)
        XCTAssertNil(BreakSplitter.largestBreak(in: "the newlines were many"))
        XCTAssertNil(BreakSplitter.largestBreak(in: ""))
    }

    func testNeverMatchesInsideALongerWord() {
        XCTAssertEqual(BreakSplitter.split("the newlines were many"), [seg("the newlines were many")])
        XCTAssertEqual(BreakSplitter.split("a new lineage"), [seg("a new lineage")])
    }

    func testLongestPhraseWins() {
        // "salto de linea" must not leave "salto de" behind as text.
        XCTAssertEqual(BreakSplitter.split("uno salto de línea dos"), [seg("uno", .line), seg("dos")])
        // ...and "break" must not be left behind by the shorter "new line".
        XCTAssertEqual(BreakSplitter.split("insert a new line break here"), [seg("insert a", .line), seg("here")])
        XCTAssertEqual(BreakSplitter.split("insert a line break here"), [seg("insert a", .line), seg("here")])
    }

    func testEveryPhraseIsAlsoAWholeUtteranceCommand() {
        for (tokens, brk) in BreakSplitter.phrases {
            let expected: VoiceCommand = brk == .line ? .newLine : .newParagraph
            XCTAssertEqual(VoiceCommand.match(tokens.joined(separator: " ")), expected, tokens.joined(separator: " "))
        }
    }

    func testEveryBreakCommandPhraseIsAlsoASplitterPhrase() {
        for (phrase, command) in VoiceCommand.phrases where command == .newLine || command == .newParagraph {
            let expected: Break = command == .newLine ? .line : .paragraph
            XCTAssertEqual(BreakSplitter.phrases[phrase.split(separator: " ").map(String.init)], expected, phrase)
        }
    }

    func testJoinUsesTheBreaks() {
        XCTAssertEqual(BreakSplitter.join([("a", .line), ("b", .paragraph), ("c", nil)]), "a\nb\n\nc")
        XCTAssertEqual(BreakSplitter.join([]), "")
    }
}

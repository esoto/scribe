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
            [seg("first line,", .line), seg("second line.", .paragraph), seg("Third.")])
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
    }

    func testNeverMatchesInsideALongerWord() {
        XCTAssertEqual(BreakSplitter.split("the newlines were many"), [seg("the newlines were many")])
        XCTAssertEqual(BreakSplitter.split("a new lineage"), [seg("a new lineage")])
    }

    func testLongestPhraseWins() {
        // "salto de linea" must not leave "salto de" behind as text.
        XCTAssertEqual(BreakSplitter.split("uno salto de línea dos"), [seg("uno", .line), seg("dos")])
    }

    func testEveryPhraseIsAlsoAWholeUtteranceCommand() {
        for (tokens, brk) in BreakSplitter.phrases {
            let expected: VoiceCommand = brk == .line ? .newLine : .newParagraph
            XCTAssertEqual(VoiceCommand.match(tokens.joined(separator: " ")), expected, tokens.joined(separator: " "))
        }
    }

    func testJoinUsesTheBreaks() {
        XCTAssertEqual(BreakSplitter.join([("a", .line), ("b", .paragraph), ("c", nil)]), "a\nb\n\nc")
        XCTAssertEqual(BreakSplitter.join([]), "")
    }
}

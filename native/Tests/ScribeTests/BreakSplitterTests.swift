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

    func testThePluralNewLinesBreaksLikeTheSingular() {
        XCTAssertEqual(
            BreakSplitter.split("one new lines two"),
            [seg("one", .line), seg("two")])
        XCTAssertEqual(BreakSplitter.largestBreak(in: "New lines."), .line)
        XCTAssertEqual(BreakSplitter.largestBreak(in: "new lines, new paragraph"), .paragraph)
        // The one-token plural stays text: only the spaced phrase is an alias.
        XCTAssertEqual(BreakSplitter.split("the newlines were many"), [seg("the newlines were many")])
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

    func testAStrayDashAfterALeadingBreakIsDropped() {
        XCTAssertEqual(BreakSplitter.split("new line — hello there"), [Segment(text: "hello there", breakAfter: nil)])
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

    // MARK: - Escape phrase

    func testAnEscapedPhraseIsTextAndTheEscapeWordsAreDropped() {
        XCTAssertEqual(BreakSplitter.split("the words new line"), [seg("new line")])
        XCTAssertEqual(BreakSplitter.split("The words, new paragraph."), [seg("new paragraph.")])
        XCTAssertEqual(
            BreakSplitter.split("first point the words new line second point"), [seg("first point new line second point")])
    }

    func testACommandPhraseInASentenceKeepsItsEscapeWords() {
        XCTAssertEqual(BreakSplitter.split("type the words enter in the box"), [seg("type the words enter in the box")])
        XCTAssertEqual(BreakSplitter.split("first the words new line second"), [seg("first new line second")])
    }

    func testTheSpanishEscapeKeepsTheOriginalAccents() {
        XCTAssertEqual(BreakSplitter.split("las palabras nueva línea"), [seg("nueva línea")])
        XCTAssertEqual(BreakSplitter.split("hola las palabras salto de línea adiós"), [seg("hola salto de línea adiós")])
    }

    func testAnEscapeNotFollowedByAPhraseStaysText() {
        XCTAssertEqual(BreakSplitter.split("the words matter"), [seg("the words matter")])
        XCTAssertEqual(BreakSplitter.split("the words"), [seg("the words")])
        XCTAssertEqual(BreakSplitter.split("one the words two new line three"), [seg("one the words two", .line), seg("three")])
    }

    func testABreakElsewhereStillSplitsWhenOnlyOneIsEscaped() {
        XCTAssertEqual(
            BreakSplitter.split("one two new line the words new line three four"),
            [seg("one two", .line), seg("new line three four")])
        XCTAssertEqual(
            BreakSplitter.split("one the words new line two new paragraph three"),
            [seg("one new line two", .paragraph), seg("three")])
    }

    func testAnEscapedPhraseIsNeverMatchedByAShorterOrOverlappingWindow() {
        // "line break" starts inside the escaped "new line break" and must not split it.
        XCTAssertEqual(BreakSplitter.split("the words new line break"), [seg("new line break")])
        XCTAssertEqual(BreakSplitter.split("a the words salto de línea b"), [seg("a salto de línea b")])
    }

    func testTheEscapeOnlyProtectsThePhraseRightAfterIt() {
        XCTAssertEqual(BreakSplitter.split("the words new line new line two"), [seg("new line", .line), seg("two")])
        XCTAssertEqual(BreakSplitter.split("new line the words new line two"), [seg("new line two")])
    }

    func testAnEscapedPhraseIsNotABreakForLargestBreak() {
        XCTAssertNil(BreakSplitter.largestBreak(in: "the words new line"))
        XCTAssertNil(BreakSplitter.largestBreak(in: "las palabras nuevo párrafo"))
        XCTAssertEqual(BreakSplitter.largestBreak(in: "the words new line new paragraph"), .paragraph)
        XCTAssertEqual(BreakSplitter.largestBreak(in: "new line the words new paragraph"), .line)
    }

    func testASentenceEndingInTheEscapeWordsIsNotAnEscape() {
        // The full stop closes the sentence, so "the words" is text and the break after it still fires.
        XCTAssertEqual(
            BreakSplitter.split("I can't find the words. New line. Next one"),
            [seg("I can't find the words.", .line), seg("Next one")])
        XCTAssertEqual(
            BreakSplitter.split("Remember the words? New paragraph. Then go"),
            [seg("Remember the words?", .paragraph), seg("Then go")])
        XCTAssertEqual(
            BreakSplitter.split("Ya veo las palabras! Nueva línea. Sigue"),
            [seg("Ya veo las palabras!", .line), seg("Sigue")])
        XCTAssertEqual(BreakSplitter.largestBreak(in: "I can't find the words. New paragraph. Next one"), .paragraph)
    }

    func testAnEscapeThatOpensTheUtteranceStillWorksAfterASentenceEnd() {
        XCTAssertEqual(BreakSplitter.split("The words. New line."), [seg("New line.")])
        XCTAssertNil(BreakSplitter.largestBreak(in: "The words. New line."))
    }

    func testACommaAfterTheEscapeWordsDoesNotBlockIt() {
        XCTAssertEqual(BreakSplitter.split("find the words, new line here"), [seg("find new line here")])
    }

    func testJoinUsesTheBreaks() {
        XCTAssertEqual(BreakSplitter.join([("a", .line), ("b", .paragraph), ("c", nil)]), "a\nb\n\nc")
        XCTAssertEqual(BreakSplitter.join([]), "")
    }
}

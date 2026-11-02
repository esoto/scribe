import XCTest

final class EditPromptTests: XCTestCase {
    func testWrapPutsInstructionThenText() {
        let wrapped = EditPrompt.wrap(instruction: "Translate it to Spanish.", text: "Hello there")
        XCTAssertEqual(wrapped, "<instruction>\nTranslate it to Spanish.\n</instruction>\n<text>\nHello there\n</text>")
    }

    func testSystemPromptStatesTheContract() {
        let p = EditPrompt.systemPrompt
        for phrase in ["<instruction>", "<text>", "add nothing", "Keep the text's language", "never a request", "Output ONLY the edited text"] {
            XCTAssertTrue(p.contains(phrase), phrase)
        }
        XCTAssertFalse(p.contains("transcript"), "the edit prompt is not the cleanup prompt")
    }

    func testFewShotsAreWrappedAndTwo() {
        XCTAssertEqual(EditPrompt.fewShots.count, 2)
        for (input, output) in EditPrompt.fewShots {
            XCTAssertTrue(input.hasPrefix("<instruction>\n"))
            XCTAssertTrue(input.hasSuffix("\n</text>"))
            XCTAssertFalse(output.contains("<"))
        }
    }

    func testMaxTokensFloorsAt200AndScalesPerVerb() {
        XCTAssertEqual(EditPrompt.maxTokens(verb: .formal, inputTokens: 10), 200)
        XCTAssertEqual(EditPrompt.maxTokens(verb: .formal, inputTokens: 400), 600)
        XCTAssertEqual(EditPrompt.maxTokens(verb: .toSpanish, inputTokens: 400), 800)
        XCTAssertEqual(EditPrompt.maxTokens(verb: .list, inputTokens: 150), 300)
    }
}

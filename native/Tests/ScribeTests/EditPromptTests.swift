import XCTest

final class EditPromptTests: XCTestCase {
    func testWrapPutsInstructionThenText() {
        let wrapped = EditPrompt.wrap(instruction: "Translate it to Spanish.", text: "Hello there")
        XCTAssertEqual(wrapped, "<instruction>\nTranslate it to Spanish.\n</instruction>\n<text>\nHello there\n</text>")
    }

    func testSystemPromptStatesTheContract() {
        let p = EditPrompt.systemPrompt
        for phrase in ["<instruction>", "<text>", "Keep every fact, name, number", "add nothing", "Keep the text's language", "unless the instruction is a translation", "never a request", "Output ONLY the edited text"] {
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

    func testEveryInstructionLineIsPinned() {
        let lines: [(EditVerb, String)] = [
            (.shorter, "Rewrite it shorter, keeping its meaning."),
            (.fixGrammar, "Fix grammar, spelling and punctuation; change nothing else."),
            (.formal, "Rewrite it in a formal register."),
            (.casual, "Rewrite it in a casual, friendly register."),
            (.list, "Turn it into a bulleted list, one point per line, each line starting with \"- \"."),
            (.toSpanish, "Translate it to Spanish."),
            (.toEnglish, "Translate it to English."),
        ]
        for (verb, line) in lines { XCTAssertEqual(verb.instruction, line, "\(verb)") }
    }

    /// The model is taught these outputs, so the gate that judges its real outputs must accept them.
    func testEveryFewShotPassesItsOwnGate() {
        let open = "<text>\n", close = "\n</text>"
        for (input, output) in EditPrompt.fewShots {
            guard let verb = EditVerb.allCases.first(where: { input.hasPrefix("<instruction>\n\($0.instruction)\n</instruction>\n") }),
                  let start = input.range(of: open), input.hasSuffix(close) else {
                XCTFail("unrecognised few-shot input: \(input)"); continue
            }
            let selection = String(input[start.upperBound..<input.index(input.endIndex, offsetBy: -close.count)])
            XCTAssertEqual(EditGates.accept(verb: verb, selection: selection, result: output), .accepted(output), output)
        }
    }
}

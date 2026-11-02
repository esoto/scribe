import XCTest

final class EditGatesTests: XCTestCase {
    let en = "The report is due Tuesday, and Marcos will send it to the team after the 3 pm meeting."

    func testAcceptsAFaithfulShorterEdit() {
        let v = EditGates.accept(verb: .shorter, selection: en, result: "Marcos sends the report Tuesday after the 3 pm meeting.")
        XCTAssertEqual(v, .accepted("Marcos sends the report Tuesday after the 3 pm meeting."))
    }

    func testEmptyIsRejectedFirst() {
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: "  \n"), .rejected(.empty))
    }

    func testPreambleTagOrEchoedInstructionIsAnswered() {
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: "Sure! " + en), .rejected(.answered))
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: "Here is the formal version: " + en), .rejected(.answered))
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: "<text>\n" + en + "\n</text>"), .rejected(.answered))
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: EditVerb.formal.instruction + " " + en), .rejected(.answered))
        XCTAssertEqual(EditGates.accept(verb: .casual, selection: "Claro que sí, voy mañana.", result: "Claro que sí, voy mañana."), .accepted("Claro que sí, voy mañana."), "a selection that itself starts with a preamble word is not an answer")
    }

    func testLengthBandPerVerb() {
        XCTAssertEqual(EditGates.accept(verb: .shorter, selection: en, result: en + " " + en), .rejected(.length))
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: en, result: "Due Tuesday."), .rejected(.length))
    }

    func testLanguageMustHoldExceptForTranslations() {
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: "El informe se entrega el martes. Marcos lo enviará al equipo después de la reunión de las 3 pm."), .rejected(.language))
        XCTAssertEqual(EditGates.accept(verb: .toSpanish, selection: en, result: "El informe se entrega el martes. Marcos lo enviará al equipo después de la reunión de las 3 pm."), .accepted("El informe se entrega el martes. Marcos lo enviará al equipo después de la reunión de las 3 pm."))
        XCTAssertEqual(EditGates.accept(verb: .toSpanish, selection: en, result: "The report is due Tuesday and Marcos will send it to the team after the 3 pm meeting."), .rejected(.language))
    }

    func testNewNumbersAndNamesAreRejected() {
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: en, result: en.replacingOccurrences(of: "3 pm", with: "4 pm")), .rejected(.newFacts))
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: en, result: en.replacingOccurrences(of: "Marcos", with: "Lucía")), .rejected(.newFacts))
    }

    func testSentenceInitialCapitalsAndDroppedWordsAreFine() {
        XCTAssertEqual(EditGates.accept(verb: .shorter, selection: en, result: "Report due Tuesday. Sent after the 3 pm meeting."), .accepted("Report due Tuesday. Sent after the 3 pm meeting."))
    }

    func testTranslationsAreExemptFromTheCapitalisedWordRule() {
        let es = "El informe sale el martes. Marcos lo manda después de la reunión."
        XCTAssertEqual(EditGates.accept(verb: .toEnglish, selection: es, result: "The report goes out on Tuesday. Marcos sends it after the meeting."), .accepted("The report goes out on Tuesday. Marcos sends it after the meeting."))
    }

    func testListKeepsNewlinesAndOthersCollapseThem() {
        let list = "- one point\n- another point\n\n\n- last"
        XCTAssertEqual(EditGates.normalize(list, verb: .list), "- one point\n- another point\n\n- last")
        XCTAssertEqual(EditGates.normalize("a\n\nb", verb: .formal), "a b")
    }

    func testPillReasonsAndTheGemma4Hint() {
        XCTAssertEqual(EditGates.pillReason(.length, modelIsGemma4: true), "Edit rejected — length off")
        XCTAssertEqual(EditGates.pillReason(.answered, modelIsGemma4: false), "Edit rejected — answered instead of editing · Gemma 4 does this better")
        XCTAssertEqual(EditGates.pillReason(.timeout, modelIsGemma4: true), "Edit rejected — took too long")
    }
}

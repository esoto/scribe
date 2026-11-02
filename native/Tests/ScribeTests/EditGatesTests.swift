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

    func testEveryPillReasonIsPinned() {
        let reasons: [(EditRejection, String)] = [
            (.empty, "came back empty"), (.answered, "answered instead of editing"), (.length, "length off"),
            (.language, "language changed"), (.newFacts, "added something new"), (.timeout, "took too long"),
        ]
        for (rejection, why) in reasons {
            XCTAssertEqual(EditGates.pillReason(rejection, modelIsGemma4: true), "Edit rejected — \(why)")
            XCTAssertEqual(EditGates.pillReason(rejection, modelIsGemma4: false), "Edit rejected — \(why) · Gemma 4 does this better")
        }
    }

    // MARK: gate order — an empty result cannot also be answered, and a whitespace-only one already outranks length

    func testAnsweredOutranksLength() {
        let talkative = "Sure! " + en + " " + en
        XCTAssertTrue(EditGates.answered(talkative, selection: en, verb: .shorter))
        XCTAssertFalse(Gates.lengthOk(raw: en, cleaned: talkative, band: EditVerb.shorter.lengthBand))
        XCTAssertEqual(EditGates.accept(verb: .shorter, selection: en, result: talkative), .rejected(.answered))
    }

    func testLengthOutranksLanguage() {
        let es = "El informe se entrega el martes, y Marcos lo enviará al equipo después de la reunión de las 3 pm."
        let long = es + " " + es
        XCTAssertFalse(Gates.lengthOk(raw: en, cleaned: long, band: EditVerb.formal.lengthBand))
        XCTAssertFalse(EditGates.languageOk(selection: en, result: long, verb: .formal))
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: long), .rejected(.length))
    }

    func testLanguageOutranksNewFacts() {
        let es = "El informe se entrega el martes, y Lucía lo enviará al equipo después de la reunión de las 3 pm."
        XCTAssertTrue(Gates.lengthOk(raw: en, cleaned: es, band: EditVerb.formal.lengthBand))
        XCTAssertTrue(EditGates.introducesNewFacts(selection: en, result: es, verb: .formal))
        XCTAssertFalse(EditGates.languageOk(selection: en, result: es, verb: .formal))
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: es), .rejected(.language))
    }

    // MARK: capitalising or re-spelling a word the selection has is not a new fact

    func testCapitalisingWordsTheSelectionAlreadyHasIsNotANewFact() {
        let selection = "yesterday i went home and i slept then i called marcos about the report on monday"
        let fixed = "Yesterday I went home and I slept. Then I called Marcos about the report on Monday."
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: selection, result: fixed), .accepted(fixed))
    }

    func testRestoringAnAccentIsNotANewFact() {
        let fixed = "The report goes to Lucía on Tuesday."
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: "the report goes to Lucia on Tuesday", result: fixed), .accepted(fixed))
    }

    func testAnInventedNameIsNewEvenWhenTheSelectionIsAllLowercase() {
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: "talked to marcos about monday", result: "Talked to Lucía about Monday."), .rejected(.newFacts))
    }

    // MARK: apostrophes

    func testContractingAndExpandingAreNotNewFacts() {
        let selection = "Okay so I will send it to the team on Tuesday after the meeting."
        for apostrophe in ["'", "’"] {
            let contracted = "Okay, so I\(apostrophe)ll send it to the team on Tuesday after the meeting."
            XCTAssertEqual(EditGates.accept(verb: .casual, selection: selection, result: contracted), .accepted(contracted), apostrophe)
        }
        let expanded = "Hello, I am sending it to the team on Tuesday."
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: "Hey, I'm sending it to the team on Tuesday.", result: expanded), .accepted(expanded))
    }

    func testAPossessiveOfAKnownNameIsNotANewFact() {
        let selection = "Tuesday brings the report from Marcos to the team, and the review follows after the 3 pm meeting."
        let shorter = "The team gets Marcos's report Tuesday after the 3 pm meeting."
        XCTAssertEqual(EditGates.accept(verb: .shorter, selection: selection, result: shorter), .accepted(shorter))
    }

    func testEdgeApostrophesNeitherHideNorInventAName() {
        let invented = en.replacingOccurrences(of: "Marcos", with: "'Lucía'")
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: en, result: invented), .rejected(.newFacts))
        let quotedKnown = en.replacingOccurrences(of: "Marcos", with: "'Marcos'")
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: en, result: quotedKnown), .accepted(quotedKnown))
    }

    func testASurnameWithAnApostropheIsNotExcusedByAShortStem() {
        let selection = "El informe es para el martes o el jueves, y se lo mandamos al equipo."
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: selection, result: "El informe es para el martes o el jueves, y se lo mandamos a O'Brien."), .rejected(.newFacts))
    }

    // MARK: preambles are matched folded

    func testHeresPreambleIsAnsweredWithEitherApostrophe() {
        for apostrophe in ["'", "’"] {
            XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: "Here\(apostrophe)s the formal version: " + en), .rejected(.answered), apostrophe)
        }
        let selection = "Here's the plan for Tuesday, and Marcos will send it."
        let edited = "Here's the plan for Tuesday; Marcos will send it."
        XCTAssertEqual(EditGates.accept(verb: .casual, selection: selection, result: edited), .accepted(edited), "a selection that opens with here's is not an answer")
    }

    func testEveryPreambleIsStoredFolded() {
        for preamble in EditGates.preambles {
            XCTAssertEqual(VoiceCommand.fold(preamble), preamble, "an unfolded preamble can never match a folded result")
        }
    }

    func testALoneClosingTagIsAnswered() {
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: en + "\n</text>"), .rejected(.answered))
        XCTAssertEqual(EditGates.accept(verb: .formal, selection: en, result: en + " </instruction>"), .rejected(.answered))
    }

    // MARK: sentence starts

    func testAColonDoesNotOpenASentence() {
        let labelled = en.replacingOccurrences(of: ", and Marcos", with: ": Lucía")
        XCTAssertEqual(EditGates.accept(verb: .fixGrammar, selection: en, result: labelled), .rejected(.newFacts))
    }

    func testEverySentenceEndOpensASentence() {
        for end in [".", "?", "!"] {
            let result = "Report due Tuesday\(end) Soon after the 3 pm meeting."
            XCTAssertEqual(EditGates.accept(verb: .shorter, selection: en, result: result), .accepted(result), end)
        }
        for newline in ["\n", "\r\n"] {
            let result = "- The report is due Tuesday\(newline)- Soon after the 3 pm meeting\(newline)- Marcos sends it"
            let lines = result.replacingOccurrences(of: "\r\n", with: "\n")
            XCTAssertEqual(EditGates.accept(verb: .list, selection: en, result: result), .accepted(lines), newline.debugDescription)
        }
    }

    func testListNormalisationSplitsOnCRLFToo() {
        XCTAssertEqual(EditGates.normalize("- one\r\n- two\r\n\r\n\r\n- three\r\n", verb: .list), "- one\n- two\n\n- three")
    }
}

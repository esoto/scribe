import XCTest

/// The pass/fail rule behind `edit.json` and `edit_guard.json`. Pure, so a broken checker is caught here and not by a
/// GPU run that reports every model green.
final class EditGoldenSupportTests: XCTestCase {
    private let shorterSelection =
        "I just wanted to quickly let you know that Marcos will present the quarterly numbers on Thursday at 10 in the main room, and it would be great if everybody could arrive 5 minutes early."
    private let shorterGood = "Marcos presents the quarterly numbers on Thursday at 10 in the main room; arrive 5 minutes early."

    private func makeCase(
        verb: String = "shorter", text: String? = nil, mustContain: [String] = [], mustNotContain: [String] = [],
        mustNotContainCased: [String]? = nil
    ) -> EditCase {
        EditCase(
            id: "x", verb: verb, text: text ?? shorterSelection, mustContain: mustContain, mustNotContain: mustNotContain,
            mustNotContainCased: mustNotContainCased, comment: nil, knownFailures: nil)
    }

    private func passed(_ testCase: EditCase, _ output: String) -> Bool {
        editCasePassed(evaluateEditCase(testCase, rawOutput: output))
    }

    // MARK: the gates run first

    func testAnAcceptedOutputWithEveryPhrasePasses() {
        let testCase = makeCase(mustContain: ["marcos", "thursday", "10", "5"], mustNotContain: ["i just wanted"])
        let result = evaluateEditCase(testCase, rawOutput: shorterGood)
        XCTAssertEqual(result.verdict, .accepted(shorterGood))
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.present, [])
        XCTAssertTrue(editCasePassed(result))
    }

    func testAGateRejectionFailsTheCaseEvenWhenEveryPhraseIsThere() {
        let testCase = makeCase(mustContain: ["marcos", "thursday"])
        let preamble = evaluateEditCase(testCase, rawOutput: "Sure! \(shorterGood)")
        XCTAssertEqual(preamble.verdict, .rejected(.answered))
        XCTAssertFalse(editCasePassed(preamble))

        let newNumber = evaluateEditCase(testCase, rawOutput: "Marcos presents the quarterly numbers on Thursday at 11 in the main room.")
        XCTAssertEqual(newNumber.verdict, .rejected(.newFacts))
        XCTAssertFalse(editCasePassed(newNumber))

        XCTAssertEqual(evaluateEditCase(testCase, rawOutput: "  ").verdict, .rejected(.empty))
    }

    func testARejectedOutputReportsNoPhrasesBecauseThereIsNoAcceptedTextToCheck() {
        let result = evaluateEditCase(makeCase(mustContain: ["nowhere"], mustNotContain: ["marcos"]), rawOutput: "Sure! \(shorterGood)")
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.present, [])
    }

    // MARK: the phrase checks on the accepted text

    func testAMissingPhraseIsReportedAndFailsTheCase() {
        let testCase = makeCase(mustContain: ["marcos", "friday"])
        let result = evaluateEditCase(testCase, rawOutput: shorterGood)
        XCTAssertEqual(result.verdict, .accepted(shorterGood))
        XCTAssertEqual(result.missing, ["friday"])
        XCTAssertFalse(editCasePassed(result))
    }

    func testAForbiddenPhraseIsReportedAndFailsTheCase() {
        let testCase = makeCase(mustNotContain: ["quarterly", "moon"])
        let result = evaluateEditCase(testCase, rawOutput: shorterGood)
        XCTAssertEqual(result.present, ["quarterly"])
        XCTAssertFalse(editCasePassed(result))
    }

    func testPhrasesMatchIgnoringCase() {
        XCTAssertTrue(passed(makeCase(mustContain: ["MARCOS", "thursday"]), shorterGood))
        XCTAssertFalse(passed(makeCase(mustNotContain: ["QUARTERLY"]), shorterGood))
    }

    func testPhrasesMatchAcrossWhitespaceTheGateCollapses() {
        XCTAssertTrue(passed(makeCase(mustContain: ["thursday at 10"]), "Marcos presents the quarterly numbers on Thursday\nat 10 in the main room; arrive 5 minutes early."))
    }

    // MARK: newline phrases read the raw output

    func testANewlinePhraseInMustNotContainIsCheckedAgainstTheRawOutput() {
        let testCase = makeCase(mustNotContain: ["\n\n"])
        let output = "\(shorterGood)\n\nThanks"
        let result = evaluateEditCase(testCase, rawOutput: output)
        XCTAssertEqual(result.verdict, .accepted("\(shorterGood) Thanks"), "the gate collapses the blank line, which is why the check must read the raw text")
        XCTAssertEqual(result.present, ["\n\n"])
        XCTAssertFalse(editCasePassed(result))
        XCTAssertTrue(passed(testCase, shorterGood))
    }

    func testABulletPhraseInMustContainIsCheckedAgainstTheRawOutput() {
        let selection = "Marcos needs to book the hotel, pack the 2 laptops, and print the tickets for everyone on Saturday."
        let testCase = makeCase(verb: "list", text: selection, mustContain: ["\n- ", "hotel", "laptops", "tickets"])
        XCTAssertTrue(passed(testCase, "- Marcos books the hotel\n- Marcos packs the 2 laptops\n- Marcos prints the tickets for everyone"))

        let flat = evaluateEditCase(testCase, rawOutput: "Marcos books the hotel, packs the 2 laptops and prints the tickets for everyone.")
        XCTAssertEqual(flat.verdict, .accepted("Marcos books the hotel, packs the 2 laptops and prints the tickets for everyone."))
        XCTAssertEqual(flat.missing, ["\n- "])
        XCTAssertFalse(editCasePassed(flat))
    }

    // MARK: case-sensitive phrases, for what a lowercase compare cannot see

    func testACasedPhraseMatchesCaseSensitively() {
        let selection = "marcos said the price of the stock rose on thursday and he will present the 12 slides to the board"
        let testCase = makeCase(verb: "fixGrammar", text: selection, mustContain: ["marcos"], mustNotContain: [], mustNotContainCased: ["Rose"])
        let promoted = evaluateEditCase(testCase, rawOutput: "Marcos said the price of the stock Rose on Thursday and he will present the 12 slides to the board.")
        XCTAssertEqual(promoted.present, ["Rose"], "gate 5 lets a selection word be capitalised into a name; only this check sees it")
        XCTAssertFalse(editCasePassed(promoted))
        XCTAssertTrue(passed(testCase, "Marcos said the price of the stock rose on Thursday and he will present the 12 slides to the board."))
    }

    func testAbsentCasedListMeansNothingIsChecked() {
        XCTAssertTrue(passed(makeCase(mustNotContainCased: nil), shorterGood))
        XCTAssertTrue(passed(makeCase(mustNotContainCased: []), shorterGood))
    }

    // MARK: verbs

    func testTheVerbIsTheRawValue() {
        XCTAssertEqual(makeCase(verb: "fixGrammar").editVerb, .fixGrammar)
        XCTAssertEqual(makeCase(verb: "toSpanish").editVerb, .toSpanish)
        XCTAssertNil(makeCase(verb: "fix_grammar").editVerb, "logName is for the log, not for the JSON")
        XCTAssertNil(makeCase(verb: "Shorter").editVerb)
    }

    func testAnUnknownVerbFailsTheCaseInsteadOfCrashing() {
        let result = evaluateEditCase(makeCase(verb: "louder"), rawOutput: shorterGood)
        XCTAssertFalse(editCasePassed(result))
        XCTAssertEqual(result.missing, ["a known verb (got louder)"])
    }

    func testEveryVerbRunsItsOwnGate() {
        let toSpanish = makeCase(verb: "toSpanish", text: "The meeting with Marcos is on Tuesday at 10 in the main room, so please bring the signed contract.")
        let spanish = "La reunión con Marcos es el martes a las 10 en la sala principal, así que por favor traigan el contrato firmado."
        XCTAssertTrue(passed(toSpanish, spanish))
        XCTAssertEqual(
            evaluateEditCase(toSpanish, rawOutput: "The meeting with Marcos is on Tuesday at 10 in the main room, so please bring the signed contract.").verdict,
            .rejected(.language))
    }

    // MARK: the JSON shape

    func testASetDecodesFromSnakeCaseAndOptionalKeysMayBeAbsent() throws {
        let json = """
            {"description":"d","cases":[
              {"id":"a","verb":"shorter","text":"t","must_contain":["x"],"must_not_contain":[]},
              {"id":"b","verb":"list","text":"u","must_contain":[],"must_not_contain":["y"],
               "must_not_contain_cased":["Rose"],"comment":"c","known_failures":["gemma4"]}
            ]}
            """
        let set = try JSONDecoder().decode(EditCaseSet.self, from: Data(json.utf8))
        XCTAssertEqual(set.cases.map(\.id), ["a", "b"])
        XCTAssertNil(set.cases[0].knownFailures)
        XCTAssertNil(set.cases[0].mustNotContainCased)
        XCTAssertEqual(set.cases[1].mustNotContainCased, ["Rose"])
        XCTAssertEqual(set.cases[1].knownFailures, ["gemma4"])
        XCTAssertEqual(set.cases[1].editVerb, .list)
    }

    func testASetMissingARequiredKeyDoesNotDecode() {
        let json = #"{"cases":[{"id":"a","verb":"shorter","text":"t","must_contain":[]}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(EditCaseSet.self, from: Data(json.utf8)))
    }

    func testLoadEditSetReadsARepoFileAndFailsLoudlyOnAMissingOne() {
        XCTAssertThrowsError(try loadEditSet("no-such-edit-set.json"))
    }
}

import XCTest

/// The pass/fail rule behind `edit.json` and `edit_guard.json`. Pure, so a broken checker is caught here and not by a
/// GPU run that reports every model green.
private struct LatencyBoom: Error, CustomStringConvertible {
    let description = "the user's selection text"
}

final class EditGoldenSupportTests: XCTestCase {
    private let shorterSelection =
        "I just wanted to quickly let you know that Marcos will present the quarterly numbers on Thursday at 10 in the main room, and it would be great if everybody could arrive 5 minutes early."
    private let shorterGood = "Marcos presents the quarterly numbers on Thursday at 10 in the main room; arrive 5 minutes early."

    private func makeCase(
        verb: String = "shorter", text: String? = nil, mustContain: [String] = [], mustContainAny: [[String]]? = nil,
        mustNotContain: [String] = [], mustNotContainCased: [String]? = nil
    ) -> EditCase {
        EditCase(
            id: "x", verb: verb, text: text ?? shorterSelection, mustContain: mustContain, mustContainAny: mustContainAny,
            mustNotContain: mustNotContain, mustNotContainCased: mustNotContainCased, comment: nil, knownFailures: nil)
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

    // MARK: an indented bullet is still a bullet

    private let listSelection = "Marcos needs to book the hotel, pack the 2 laptops, and print the tickets for everyone on Saturday."

    func testAnIndentedBulletCountsForTheNewlinePhrase() {
        let testCase = makeCase(verb: "list", text: listSelection, mustContain: ["\n- ", "hotel"])
        XCTAssertTrue(passed(testCase, "  - Marcos books the hotel\n  - Marcos packs the 2 laptops\n\t- Marcos prints the tickets for everyone"), "spaces and tabs before the dash")
        XCTAssertTrue(passed(testCase, "- Marcos books the hotel\r\n   - Marcos packs the 2 laptops\r\n- Marcos prints the tickets for everyone"), "CRLF line ends")
    }

    func testAnIndentedForbiddenMarkerIsStillForbidden() {
        let testCase = makeCase(verb: "list", text: listSelection, mustContain: ["\n- "], mustNotContain: ["\n* "])
        let result = evaluateEditCase(testCase, rawOutput: "- Marcos books the hotel\n  * Marcos packs the 2 laptops\n  * Marcos prints the tickets for everyone")
        XCTAssertEqual(result.present, ["\n* "])
        XCTAssertFalse(editCasePassed(result))
    }

    func testAListWithoutAnyBulletStillMissesTheBulletPhrase() {
        let testCase = makeCase(verb: "list", text: listSelection, mustContain: ["\n- "])
        let result = evaluateEditCase(testCase, rawOutput: "Marcos books the hotel\n   packs the 2 laptops\n   prints the tickets for everyone")
        XCTAssertEqual(result.missing, ["\n- "])
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

    // MARK: what a failed case reports

    func testTheFailureMessageNamesAGateRejectionAndShowsInputAndOutput() {
        let testCase = makeCase(mustContain: ["marcos"])
        let raw = "Sure! \(shorterGood)"
        let message = editFailureMessage(testCase, evaluateEditCase(testCase, rawOutput: raw), shown: raw)
        XCTAssertTrue(message.hasPrefix("[x] gate rejected the output: answered"), message)
        XCTAssertTrue(message.contains("input:  \(shorterSelection)"), message)
        XCTAssertTrue(message.contains("output: \(raw)"), message)
    }

    func testTheFailureMessageListsBothPhraseListsWhenTheGatesAccepted() {
        let testCase = makeCase(mustContain: ["marcos", "friday"], mustNotContain: ["quarterly"])
        let message = editFailureMessage(testCase, evaluateEditCase(testCase, rawOutput: shorterGood), shown: shorterGood)
        XCTAssertTrue(message.contains("missing [\"friday\"]"), message)
        XCTAssertTrue(message.contains("must not contain [\"quarterly\"]"), message)
        XCTAssertFalse(message.contains("gate rejected"), message)
    }

    func testTheLatencyErrorLineNamesTheErrorTypeAndNeverItsText() {
        let line = editLatencyErrorLine(model: "gemma3", verb: .fixGrammar, error: LatencyBoom())
        XCTAssertEqual(line, "edit_latency[gemma3] verb=fixGrammar error=LatencyBoom")
        XCTAssertFalse(line.contains("selection"), "an error can quote the prompt; a selection never reaches a log line")
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

    // MARK: must_contain_any — one of several spellings of the same fact

    func testAnAlternativesGroupPassesWithAnyOneOfItsPhrases() {
        let testCase = makeCase(mustContain: ["marcos"], mustContainAny: [["10", "ten"], ["5", "five"]])
        XCTAssertTrue(passed(testCase, shorterGood), "digits")
        let spelled = "Marcos presents the quarterly numbers on Thursday at ten in the main room; arrive five minutes early."
        let result = evaluateEditCase(testCase, rawOutput: spelled)
        XCTAssertEqual(result.verdict, .accepted(spelled))
        XCTAssertEqual(result.missing, [])
        XCTAssertTrue(editCasePassed(result), "number words")
        let mixed = "Marcos presents the quarterly numbers on Thursday at 10 in the main room; arrive five minutes early."
        XCTAssertTrue(passed(testCase, mixed), "one group each way")
    }

    func testAnUnsatisfiedGroupIsReportedAsItsAlternativesAndFailsTheCase() {
        let testCase = makeCase(mustContain: ["marcos"], mustContainAny: [["10", "ten"], ["7", "seven"]])
        let result = evaluateEditCase(testCase, rawOutput: shorterGood)
        XCTAssertEqual(result.verdict, .accepted(shorterGood))
        XCTAssertEqual(result.missing, ["7 or seven"], "the group that held is not reported")
        XCTAssertFalse(editCasePassed(result))
    }

    func testPlainPhrasesAndGroupsAreBothReportedWhenBothAreMissing() {
        let testCase = makeCase(mustContain: ["friday"], mustContainAny: [["7", "seven"]])
        XCTAssertEqual(evaluateEditCase(testCase, rawOutput: shorterGood).missing, ["friday", "7 or seven"])
    }

    func testAnEmptyGroupCanNeverBeSatisfiedSoItFailsInsteadOfPassingSilently() {
        let result = evaluateEditCase(makeCase(mustContainAny: [[]]), rawOutput: shorterGood)
        XCTAssertFalse(editCasePassed(result))
        XCTAssertEqual(result.missing.count, 1)
    }

    func testAbsentOrEmptyGroupsCheckNothing() {
        XCTAssertTrue(passed(makeCase(mustContainAny: nil), shorterGood))
        XCTAssertTrue(passed(makeCase(mustContainAny: []), shorterGood))
    }

    func testGroupsAreComparedAgainstTheAcceptedTextIgnoringCase() {
        let testCase = makeCase(mustContainAny: [["THURSDAY", "jueves"]])
        XCTAssertTrue(passed(testCase, shorterGood))
        let rejected = evaluateEditCase(testCase, rawOutput: "Sure! \(shorterGood)")
        XCTAssertEqual(rejected.missing, [], "a rejected output has no accepted text to check, groups included")
    }

    /// "ten" sits inside "often" and Spanish "dos" inside "todos", which a Spanish selection says all the time: a
    /// substring check would pass every output that dropped the number.
    func testAGroupPhraseMustAppearAsAWholeWordOrNumberNotInsideAnother() {
        let testCase = makeCase(mustContainAny: [["10", "ten"]])
        let dropped = "Marcos often presents the quarterly numbers on Thursday in the main room; arrive 5 minutes early."
        let result = evaluateEditCase(testCase, rawOutput: dropped)
        XCTAssertEqual(result.verdict, .accepted(dropped))
        XCTAssertEqual(result.missing, ["10 or ten"])
    }

    func testContainsTokenRespectsWordAndNumberBoundaries() {
        XCTAssertFalse(containsToken("para todos", "dos"))
        XCTAssertTrue(containsToken("los dos libros", "dos"))
        XCTAssertTrue(containsToken("son dos.", "dos"))
        XCTAssertTrue(containsToken("dos", "dos"))
        XCTAssertFalse(containsToken("the 13 reports", "3"))
        XCTAssertFalse(containsToken("the 35 reports", "3"))
        XCTAssertTrue(containsToken("at 3:30", "3"))
        XCTAssertTrue(containsToken("at 3pm", "3"))
        XCTAssertTrue(containsToken("at 3, or 4", "3"))
        XCTAssertFalse(containsToken("fifteen", "five"))
        XCTAssertFalse(containsToken("nineteen", "nine"))
        XCTAssertFalse(containsToken("cuatrocientos", "cuatro"))
        XCTAssertTrue(containsToken("about four hundred fifty dollars", "four hundred fifty"))
        XCTAssertTrue(containsToken("las 9 de la mañana", "9"))
        XCTAssertTrue(containsToken("veinte", "veinte"))
        XCTAssertFalse(containsToken("", "dos"))
        XCTAssertFalse(containsToken("dos", ""))
        XCTAssertTrue(containsToken("tres cosas y tres más", "tres"), "the second occurrence is checked when the first is inside nothing")
        XCTAssertTrue(containsToken("estres y tres", "tres"), "an occurrence inside a word does not hide a later whole one")
    }

    func testTheFailureMessageShowsAMissingGroupAsItsAlternatives() {
        let testCase = makeCase(mustContainAny: [["7", "seven"]])
        let message = editFailureMessage(testCase, evaluateEditCase(testCase, rawOutput: shorterGood), shown: shorterGood)
        XCTAssertTrue(message.contains("missing [\"7 or seven\"]"), message)
    }

    // MARK: the gate line of an eval

    private func gateLine(_ testCase: EditCase, _ output: String) -> String? {
        editGateLine(testCase, evaluateEditCase(testCase, rawOutput: output), shown: EditGates.normalize(output, verb: testCase.editVerb ?? .shorter))
    }

    func testAnAcceptedOutputPrintsNoGateLine() {
        XCTAssertNil(gateLine(makeCase(), shorterGood))
    }

    func testALengthRejectionPrintsTheRatioAndTheBand() {
        let selection = String(repeating: "ab ", count: 33) + "a"
        let tooShort = String(repeating: "ab ", count: 11) + "a"
        XCTAssertEqual(
            gateLine(makeCase(verb: "casual", text: selection), tooShort),
            "gate: rejected (length ratio=0.34 band=0.35–1.4)")
        let tooLong = String(repeating: "ab ", count: 43) + "a"
        XCTAssertEqual(
            gateLine(makeCase(verb: "fixGrammar", text: selection), tooLong),
            "gate: rejected (length ratio=1.30 band=0.8–1.25)")
    }

    func testEveryOtherRejectionPrintsJustItsName() {
        XCTAssertEqual(gateLine(makeCase(), "Sure! \(shorterGood)"), "gate: rejected (answered)")
        XCTAssertEqual(gateLine(makeCase(), "Marcos presents the quarterly numbers on Thursday at 11 in the main room."), "gate: rejected (newFacts)")
        XCTAssertEqual(gateLine(makeCase(), "  "), "gate: rejected (empty)")
    }

    func testAnUnknownVerbPrintsItsRejectionWithoutABand() {
        XCTAssertEqual(gateLine(makeCase(verb: "louder"), shorterGood), "gate: rejected (empty)")
    }

    // MARK: the JSON shape of the new field

    func testASetDecodesMustContainAnyAndItMayBeAbsent() throws {
        let json = """
            {"cases":[
              {"id":"a","verb":"shorter","text":"t","must_contain":[],"must_not_contain":[]},
              {"id":"b","verb":"shorter","text":"t","must_contain":["x"],"must_contain_any":[["3","three"],["10","ten"]],"must_not_contain":[]}
            ]}
            """
        let set = try JSONDecoder().decode(EditCaseSet.self, from: Data(json.utf8))
        XCTAssertNil(set.cases[0].mustContainAny)
        XCTAssertEqual(set.cases[1].mustContainAny, [["3", "three"], ["10", "ten"]])
    }
}

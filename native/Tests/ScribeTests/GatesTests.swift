import XCTest

final class GatesTests: XCTestCase {
    func testRmsSilenceVsTone() {
        XCTAssertEqual(Gates.rms([Float](repeating: 0, count: 1600)), 0.0)
        let tone = (0..<1600).map { Float(0.1 * sin(Double($0) * 100.0 / 1600.0)) }
        XCTAssertGreaterThan(Gates.rms(tone), 0.05)
    }
    /// Float accumulation drifts on long quiet buffers and can flip the energy gate; keep Double.
    func testRmsMatchesDoubleReferenceOnLongQuietBuffer() {
        let pcm = (0..<960_000).map { Float(0.0005 * sin(Double($0) * 0.037)) }
        let reference = (pcm.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(pcm.count))
            .squareRoot()
        XCTAssertEqual(Gates.rms(pcm), reference, accuracy: reference * 1e-9)
    }

    func testEnergyGate() {
        XCTAssertFalse(Gates.passesEnergyGate([Float](repeating: 0, count: 100), threshold: 0.0005))
        XCTAssertFalse(Gates.passesEnergyGate([], threshold: 0.0005))
        XCTAssertTrue(Gates.passesEnergyGate([Float](repeating: 0.1, count: 100), threshold: 0.0005))
    }
    func testShouldClean() {
        XCTAssertTrue(Gates.shouldClean("one two three four", enabled: true, minWords: 4))
        XCTAssertFalse(Gates.shouldClean("one two three", enabled: true, minWords: 4))
        XCTAssertFalse(Gates.shouldClean("one two three four", enabled: false, minWords: 4))
    }
    func testLengthOk() {
        let band = (0.5, 1.3)
        XCTAssertTrue(Gates.lengthOk(raw: String(repeating: "a", count: 100), cleaned: String(repeating: "a", count: 80), band: band))
        XCTAssertFalse(Gates.lengthOk(raw: String(repeating: "a", count: 100), cleaned: String(repeating: "a", count: 20), band: band))
        XCTAssertFalse(Gates.lengthOk(raw: String(repeating: "a", count: 100), cleaned: String(repeating: "a", count: 200), band: band))
        XCTAssertFalse(Gates.lengthOk(raw: "hello", cleaned: "", band: band))
    }
    func testNormalizePreservesSpanish() {
        XCTAssertEqual(Gates.normalize("  el  martes,\n antes del mediodía.  "), "el martes, antes del mediodía.")
    }
    func testLanguageConsistentSameLanguage() {
        XCTAssertTrue(Gates.languageConsistent(raw: "so um move the meeting to friday", cleaned: "Move the meeting to Friday."))
        XCTAssertTrue(Gates.languageConsistent(raw: "este el codigo esta listo segun el equipo", cleaned: "El código está listo según el equipo."))
    }
    func testLanguageConsistentDetectsTranslation() {
        XCTAssertFalse(Gates.languageConsistent(raw: "digamos que el deploy se hace el viernes antes de las cinco", cleaned: "The deploy is done on Friday or before five."))
        XCTAssertFalse(Gates.languageConsistent(raw: "do you think we should ship this on friday", cleaned: "¿Deberíamos enviar esto el viernes?"))
    }
    func testLanguageConsistentNeutralPasses() {
        XCTAssertTrue(Gates.languageConsistent(raw: "ok deploy prod 123", cleaned: "Ok, deploy prod 123."))
    }
    func testLangScoreCountsStopwordsThatCarryPunctuation() {
        XCTAssertEqual(Gates.langScore("The, dog."), 1)
        XCTAssertEqual(Gates.langScore("Creo que."), -1)
        XCTAssertEqual(Gates.langScore("¿Es esto, eso?"), -3, "inverted punctuation hides nothing either")
        XCTAssertEqual(Gates.langScore("Yes, we should, they would."), 4)
    }
    func testLanguageConsistentDetectsTranslationOfPunctuatedText() {
        XCTAssertFalse(Gates.languageConsistent(
            raw: "Creo que el reporte es para el lunes.", cleaned: "I think the report is for Monday."))
        // Every stopword carries punctuation, so a whitespace split saw none of them and both sides scored 0.
        XCTAssertFalse(Gates.languageConsistent(
            raw: "Que, se, eso, es. Yo, ellos.", cleaned: "It is, we do, they would."))
    }
    func testLanguageConsistentPunctuatedSameLanguagePasses() {
        XCTAssertTrue(Gates.languageConsistent(
            raw: "so um, move the, meeting to friday.", cleaned: "Move the meeting to Friday."))
        XCTAssertTrue(Gates.languageConsistent(
            raw: "pues, el, código está listo, según el equipo.", cleaned: "El código está listo, según el equipo."))
    }
    func testLanguageConsistentPunctuatedNeutralPasses() {
        XCTAssertTrue(Gates.languageConsistent(raw: "ok, deploy, prod.", cleaned: "Ok. Deploy prod."))
    }
}

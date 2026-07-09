import XCTest
@testable import Scribe

final class GatesTests: XCTestCase {
    func testRmsSilenceVsTone() {
        XCTAssertEqual(Gates.rms([Float](repeating: 0, count: 1600)), 0.0)
        let tone = (0..<1600).map { Float(0.1 * sin(Double($0) * 100.0 / 1600.0)) }
        XCTAssertGreaterThan(Gates.rms(tone), 0.05)
    }
    /// Pins Double accumulation in the vDSP rms: on a long quiet buffer a
    /// Float accumulator drifts from the true value, which can flip a
    /// borderline energy-gate decision and silently discard a dictation.
    func testRmsMatchesDoubleReferenceOnLongQuietBuffer() {
        // 60 s at 16 kHz of a quiet tone right at the default gate scale.
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
}

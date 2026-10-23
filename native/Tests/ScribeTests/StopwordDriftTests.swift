import XCTest

final class StopwordDriftTests: XCTestCase {
    func testSpanishReadsZeroAndEnglishReadsOne() {
        XCTAssertEqual(StopwordDrift.hits(StopwordDrift.words("Creo que el reporte es para el lunes.")).ratio, 0)
        XCTAssertEqual(StopwordDrift.hits(StopwordDrift.words("I think the report is for Monday.")).ratio, 1)
    }

    func testPunctuatedStopwordsCount() {
        XCTAssertEqual(StopwordDrift.hits(StopwordDrift.words("the, and. que,")), .init(en: 2, es: 1))
    }

    func testWordInBothListsIsSkipped() {
        XCTAssertEqual(StopwordDrift.hits(["a", "a", "el"]), .init(en: 0, es: 1))
    }

    func testNoHitsReportsZeroCounts() {
        XCTAssertEqual(StopwordDrift.hits(StopwordDrift.words("Mañana 1234 xyz")), .init(en: 0, es: 0))
    }

    func testLateDriftShowsInTheLastThirdButNotOverall() {
        let words = Array(repeating: "que", count: 6) + Array(repeating: "the", count: 4)
        XCTAssertLessThan(StopwordDrift.hits(words).ratio, 0.5)
        XCTAssertEqual(StopwordDrift.thirds(words).map(\.ratio), [0, 0.5, 1])
    }
}

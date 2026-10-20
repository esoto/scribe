import XCTest

final class URLCommandTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testParsesBothSpellingsOfPasteLast() {
        XCTAssertEqual(URLCommand.parse(url("scribe://paste-last")), .pasteLast)
        XCTAssertEqual(URLCommand.parse(url("scribe://paste-last/")), .pasteLast)
        XCTAssertEqual(URLCommand.parse(url("scribe:paste-last")), .pasteLast)
        XCTAssertEqual(URLCommand.parse(url("SCRIBE://Paste-Last")), .pasteLast)
    }

    func testRefusesAnythingWithAPayload() {
        XCTAssertNil(URLCommand.parse(url("scribe://paste-last?text=hi")))
        XCTAssertNil(URLCommand.parse(url("scribe://paste-last#x")))
        XCTAssertNil(URLCommand.parse(url("scribe://paste-last/extra")))
        XCTAssertNil(URLCommand.parse(url("scribe://user@paste-last")))
    }

    func testRefusesOtherSchemesAndUnknownVerbs() {
        XCTAssertNil(URLCommand.parse(url("https://paste-last")))
        XCTAssertNil(URLCommand.parse(url("scribe://toggle")))
        XCTAssertNil(URLCommand.parse(url("scribe://")))
        XCTAssertNil(URLCommand.parse(url("scribe:")))
    }

    func testOutcomeRunsOnlyWhenEnabled() {
        XCTAssertEqual(URLCommand.outcome(for: url("scribe://paste-last"), enabled: true), .run(.pasteLast))
        XCTAssertEqual(URLCommand.outcome(for: url("scribe://paste-last"), enabled: false), .refusedOff)
        // A URL that isn't ours is ignored whether or not the scheme is on.
        XCTAssertEqual(URLCommand.outcome(for: url("scribe://nope"), enabled: true), .ignored)
        XCTAssertEqual(URLCommand.outcome(for: url("scribe://nope"), enabled: false), .ignored)
    }
}

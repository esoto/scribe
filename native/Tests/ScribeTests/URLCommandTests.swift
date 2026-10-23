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
        XCTAssertNil(URLCommand.parse(url("scribe://paste-last:80")))
    }

    func testRefusesOtherSchemesAndUnknownVerbs() {
        XCTAssertNil(URLCommand.parse(url("https://paste-last")))
        XCTAssertNil(URLCommand.parse(url("scribe://latch")))
        XCTAssertNil(URLCommand.parse(url("scribe://")))
        XCTAssertNil(URLCommand.parse(url("scribe:")))
    }

    func testParsesToggle() {
        XCTAssertEqual(URLCommand.parse(url("scribe://toggle")), .toggle)
        XCTAssertEqual(URLCommand.parse(url("scribe:toggle")), .toggle)
    }

    func testOutcomeRunsOnlyWhenEnabled() {
        XCTAssertEqual(URLCommand.outcome(for: url("scribe://paste-last"), enabled: true), .run(.pasteLast))
        XCTAssertEqual(URLCommand.outcome(for: url("scribe://paste-last"), enabled: false), .refusedOff)
        // A URL that isn't ours is ignored whether or not the scheme is on.
        XCTAssertEqual(URLCommand.outcome(for: url("scribe://nope"), enabled: true), .ignored)
        XCTAssertEqual(URLCommand.outcome(for: url("scribe://nope"), enabled: false), .ignored)
    }

    func testIgnoredLogLineNeverEchoesTheURL() {
        XCTAssertEqual(URLCommand.ignoredLogLine(for: url("scribe://my%20secret%20text")), "url ignored: not a scribe:// command")
        XCTAssertEqual(URLCommand.ignoredLogLine(for: url("scribe://x%0A2026-10-19T00%3A00%3A00Z%20models%20ready")), "url ignored: not a scribe:// command")
        XCTAssertEqual(URLCommand.ignoredLogLine(for: URL(fileURLWithPath: "/tmp/notes.txt")), "url ignored: a file was opened")
    }

    func testRefusalNoticeIsThrottledToOnePerThirtySeconds() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(URLCommand.shouldNotifyRefusal(lastAt: nil, now: t0))
        XCTAssertFalse(URLCommand.shouldNotifyRefusal(lastAt: t0, now: t0.addingTimeInterval(10)))
        XCTAssertTrue(URLCommand.shouldNotifyRefusal(lastAt: t0, now: t0.addingTimeInterval(31)))
    }
}

import XCTest

final class URLHandoffTests: XCTestCase {
    private let toggle = URL(string: "scribe://toggle")!
    private let pasteLast = URL(string: "scribe://paste-last")!

    func testURLsFiredBeforeTheHandlerAreDeliveredInOrderOnSet() {
        let handoff = URLHandoff()
        handoff.fire(toggle)
        handoff.fire(pasteLast)
        var seen: [URL] = []

        handoff.set { seen.append($0) }

        XCTAssertEqual(seen, [toggle, pasteLast])
    }

    func testAURLFiredAfterSetIsDeliveredAtOnce() {
        let handoff = URLHandoff()
        var seen: [URL] = []
        handoff.set { seen.append($0) }

        handoff.fire(toggle)

        XCTAssertEqual(seen, [toggle])
    }

    func testABufferedURLIsDeliveredOnlyOnce() {
        let handoff = URLHandoff()
        handoff.fire(toggle)
        var first: [URL] = []
        handoff.set { first.append($0) }
        var second: [URL] = []

        handoff.set { second.append($0) }

        XCTAssertEqual(first, [toggle])
        XCTAssertEqual(second, [], "a drained URL must not run a second time")
    }

    func testSettingTwiceKeepsTheLatestHandler() {
        let handoff = URLHandoff()
        var first: [URL] = []
        var second: [URL] = []
        handoff.set { first.append($0) }
        handoff.set { second.append($0) }

        handoff.fire(toggle)

        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [toggle])
    }

    func testAHandlerMayFireWhileItDrains() {
        // The handler runs outside the lock, so a handler that fires again cannot deadlock.
        let handoff = URLHandoff()
        handoff.fire(toggle)
        var seen: [URL] = []

        handoff.set { url in
            seen.append(url)
            if url == self.toggle { handoff.fire(self.pasteLast) }
        }

        XCTAssertEqual(seen, [toggle, pasteLast])
    }
}

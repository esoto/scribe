import XCTest

// Sources/Scribe compiles into this test module, so no import is needed.

final class IdleTrackerTests: XCTestCase {
    func testDisabledWhenZero() {
        let t = IdleTracker(unloadAfterMinutes: 0)
        XCTAssertFalse(t.enabled)
        t.touch(now: 100.0)
        XCTAssertFalse(t.due(now: 100000.0))
    }

    func testNotDueBeforeAnyActivity() {
        let t = IdleTracker(unloadAfterMinutes: 15)
        XCTAssertFalse(t.due(now: 100000.0))
    }

    func testDueAfterTimeout() {
        let t = IdleTracker(unloadAfterMinutes: 15)
        t.touch(now: 1000.0)
        XCTAssertFalse(t.due(now: 1000.0 + 14 * 60))
        XCTAssertTrue(t.due(now: 1000.0 + 15 * 60))
    }

    func testActivityResetsTimer() {
        let t = IdleTracker(unloadAfterMinutes: 15)
        t.touch(now: 0.0)
        t.touch(now: 10 * 60.0)
        XCTAssertFalse(t.due(now: 20 * 60.0))
        XCTAssertTrue(t.due(now: 25 * 60.0))
    }
}

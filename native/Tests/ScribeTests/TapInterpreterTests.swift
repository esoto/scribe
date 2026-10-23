import XCTest

final class TapInterpreterTests: XCTestCase {
    func testHoldModeIsPlainDownUp() {
        var tap = TapInterpreter(mode: .hold)
        XCTAssertEqual(tap.down(at: 0), .start)
        XCTAssertEqual(tap.up(at: 1.5), .stop)
        // Two quick taps never latch in hold mode.
        XCTAssertEqual(tap.down(at: 2.0), .start)
        XCTAssertEqual(tap.up(at: 2.1), .stop)
        XCTAssertEqual(tap.down(at: 2.2), .start)
        XCTAssertEqual(tap.up(at: 2.3), .stop)
        XCTAssertFalse(tap.isLatched)
    }

    func testDoubleTapLatchesAndTheNextTapStops() {
        var tap = TapInterpreter(mode: .holdOrLatch)
        XCTAssertEqual(tap.down(at: 0), .start)
        XCTAssertEqual(tap.up(at: 0.1), .stop)
        XCTAssertEqual(tap.down(at: 0.3), .startLatched)
        XCTAssertTrue(tap.isLatched)
        XCTAssertEqual(tap.up(at: 0.4), .ignore)
        XCTAssertEqual(tap.down(at: 30), .stopLatched)
        XCTAssertFalse(tap.isLatched)
        XCTAssertEqual(tap.up(at: 30.1), .ignore)
        // Back to normal afterwards.
        XCTAssertEqual(tap.down(at: 31), .start)
        XCTAssertEqual(tap.up(at: 32), .stop)
    }

    func testALongHoldNeverStartsADoubleTap() {
        var tap = TapInterpreter(mode: .holdOrLatch)
        XCTAssertEqual(tap.down(at: 0), .start)
        XCTAssertEqual(tap.up(at: 1.0), .stop)
        XCTAssertEqual(tap.down(at: 1.1), .start)
        XCTAssertFalse(tap.isLatched)
    }

    func testTapsOutsideTheWindowDoNotLatch() {
        var tap = TapInterpreter(mode: .holdOrLatch, doubleTapWindow: 0.4)
        XCTAssertEqual(tap.down(at: 0), .start)
        XCTAssertEqual(tap.up(at: 0.1), .stop)
        XCTAssertEqual(tap.down(at: 0.6), .start)
        XCTAssertFalse(tap.isLatched)
    }

    func testTheStoppingTapDoesNotCountTowardsANewDoubleTap() {
        var tap = TapInterpreter(mode: .holdOrLatch)
        _ = tap.down(at: 0)
        _ = tap.up(at: 0.1)
        XCTAssertEqual(tap.down(at: 0.3), .startLatched)
        _ = tap.up(at: 0.4)
        XCTAssertEqual(tap.down(at: 5.0), .stopLatched)
        _ = tap.up(at: 5.1)
        XCTAssertEqual(tap.down(at: 5.3), .start)
    }

    func testResetForgetsALatch() {
        var tap = TapInterpreter(mode: .holdOrLatch)
        _ = tap.down(at: 0)
        _ = tap.up(at: 0.1)
        XCTAssertEqual(tap.down(at: 0.2), .startLatched)
        tap.reset()
        XCTAssertFalse(tap.isLatched)
        XCTAssertEqual(tap.up(at: 0.3), .ignore)
        XCTAssertEqual(tap.down(at: 1), .start)
    }

    func testModeCanChangeAtRuntime() {
        var tap = TapInterpreter(mode: .hold)
        _ = tap.down(at: 0)
        _ = tap.up(at: 0.1)
        tap.mode = .holdOrLatch
        XCTAssertEqual(tap.down(at: 0.2), .startLatched)
    }

    func testHotkeyModeRawValuesAndNames() {
        XCTAssertEqual(HotkeyMode(rawValue: "hold"), .hold)
        XCTAssertEqual(HotkeyMode(rawValue: "hold_or_latch"), .holdOrLatch)
        XCTAssertNil(HotkeyMode(rawValue: "latch"))
        XCTAssertEqual(HotkeyMode.hold.displayName, "Hold to talk")
        XCTAssertEqual(HotkeyMode.holdOrLatch.displayName, "Hold, or double-tap to latch")
    }

    func testAnExternalLatchIsStoppedByTheNextTapInAnyMode() {
        var tap = TapInterpreter(mode: .hold)
        tap.latchExternally()
        XCTAssertTrue(tap.isLatched)
        XCTAssertEqual(tap.down(at: 10), .stopLatched)
        XCTAssertEqual(tap.up(at: 10.1), .ignore)
        XCTAssertEqual(tap.down(at: 11), .start)
    }

    func testTapMaxFollowsTheHoldThreshold() {
        var tap = TapInterpreter(mode: .holdOrLatch, tapMax: 0.3)
        tap.tapMax = 1.0
        _ = tap.down(at: 0)
        _ = tap.up(at: 0.8)
        XCTAssertEqual(tap.down(at: 0.9), .startLatched)
    }
}

import AppKit
import XCTest

@MainActor
final class WindowActivationTests: XCTestCase {
    func testFirstAppearAppliesRegularOnce() {
        var applied: [NSApplication.ActivationPolicy] = []
        let w = WindowActivation(apply: { applied.append($0) })
        w.windowAppeared()
        XCTAssertEqual(applied, [.regular])
        XCTAssertEqual(w.openWindows, 1)
    }

    func testSecondAppearAppliesNothing() {
        var applied: [NSApplication.ActivationPolicy] = []
        let w = WindowActivation(apply: { applied.append($0) })
        w.windowAppeared()
        w.windowAppeared()
        XCTAssertEqual(applied, [.regular])
        XCTAssertEqual(w.openWindows, 2)
    }

    func testDisappearWithOneStillOpenAppliesNothing() {
        var applied: [NSApplication.ActivationPolicy] = []
        let w = WindowActivation(apply: { applied.append($0) })
        w.windowAppeared()
        w.windowAppeared()
        w.windowDisappeared()
        XCTAssertEqual(applied, [.regular])
        XCTAssertEqual(w.openWindows, 1)
    }

    func testLastDisappearAppliesAccessory() {
        var applied: [NSApplication.ActivationPolicy] = []
        let w = WindowActivation(apply: { applied.append($0) })
        w.windowAppeared()
        w.windowAppeared()
        w.windowDisappeared()
        w.windowDisappeared()
        XCTAssertEqual(applied, [.regular, .accessory])
        XCTAssertEqual(w.openWindows, 0)
    }

    func testStrayDisappearAtZeroAppliesAccessoryAndStaysAtZero() {
        var applied: [NSApplication.ActivationPolicy] = []
        let w = WindowActivation(apply: { applied.append($0) })
        w.windowDisappeared()
        XCTAssertEqual(applied, [.accessory])
        XCTAssertEqual(w.openWindows, 0)
    }
}

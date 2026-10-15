import XCTest

final class SettingsWindowHelpersTests: XCTestCase {
    func testHoldThresholdChoicesRunFromOneTenthToOneSecond() {
        XCTAssertEqual(holdThresholdChoices.count, 10)
        XCTAssertEqual(holdThresholdChoices.first, 0.1)
        XCTAssertEqual(holdThresholdChoices.last, 1.0)
    }

    func testEveryStoredHoldThresholdOnTheListMatchesATag() {
        // The picker matches by equality; a value that only rounds to a tag would show blank.
        for seconds in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0] {
            XCTAssertTrue(holdThresholdChoices.contains(seconds), "\(seconds)")
        }
    }

    func testIdleUnloadChoicesStartWithNever() {
        XCTAssertEqual(idleUnloadChoices, [0, 5, 15, 30, 60])
    }

    func testChoicesKeepTheListWhenTheCurrentValueIsOnIt() {
        XCTAssertEqual(pickerChoices(idleUnloadChoices, including: 15), idleUnloadChoices)
    }

    func testChoicesAddACurrentValueOutsideTheListInOrder() {
        XCTAssertEqual(pickerChoices(idleUnloadChoices, including: 10), [0, 5, 10, 15, 30, 60])
        XCTAssertEqual(pickerChoices(idleUnloadChoices, including: 120), [0, 5, 15, 30, 60, 120])
    }

    func testHoldThresholdLabels() {
        XCTAssertEqual(holdThresholdLabel(0.3), "0.3 s")
        XCTAssertEqual(holdThresholdLabel(1.0), "1.0 s")
        XCTAssertEqual(holdThresholdLabel(0.7), "0.7 s")
    }

    func testHoldThresholdLabelKeepsPrecisionForACustomValue() {
        XCTAssertEqual(holdThresholdLabel(0.25), "0.25 s")
    }

    func testIdleUnloadLabels() {
        XCTAssertEqual(idleUnloadLabel(0), "Never")
        XCTAssertEqual(idleUnloadLabel(-5), "Never")
        XCTAssertEqual(idleUnloadLabel(5), "5 min")
        XCTAssertEqual(idleUnloadLabel(60), "60 min")
    }

    func testIdleUnloadLabelKeepsPrecisionForACustomValue() {
        XCTAssertEqual(idleUnloadLabel(7.5), "7.5 min")
    }
}

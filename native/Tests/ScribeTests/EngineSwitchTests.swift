import XCTest


/// Engine-switch rules: a mid-preload switch-back must not be ignored, and a superseded model must not stay resident.
final class EngineSwitchTests: XCTestCase {
    func testSelectingActiveEngineWithNoSwitchInFlightIgnores() {
        XCTAssertEqual(
            EngineSwitch.action(selecting: "parakeet", active: "parakeet", pending: nil),
            .ignore)
    }

    func testSelectingNewEngineBegins() {
        XCTAssertEqual(
            EngineSwitch.action(selecting: "whisper", active: "parakeet", pending: nil),
            .begin)
    }

    func testReselectingPendingTargetIgnores() {
        XCTAssertEqual(
            EngineSwitch.action(selecting: "whisper", active: "parakeet", pending: "whisper"),
            .ignore)
    }

    // Switch-back mid-preload: comparing only against the stale `active` would ignore the click.
    func testSelectingActiveEngineDuringSwitchReverts() {
        XCTAssertEqual(
            EngineSwitch.action(selecting: "parakeet", active: "parakeet", pending: "whisper"),
            .revert)
    }

    func testSelectingThirdEngineDuringSwitchBegins() {
        XCTAssertEqual(
            EngineSwitch.action(selecting: "third", active: "parakeet", pending: "whisper"),
            .begin)
    }

    // Rapid A→B→C: the cancelled task must unload B, or it stays resident with no owner.
    func testSupersededEngineIsUnloadedWhenNoLongerWanted() {
        XCTAssertTrue(
            EngineSwitch.shouldUnloadSuperseded("whisper", active: "parakeet", pending: "third"))
        XCTAssertTrue(
            EngineSwitch.shouldUnloadSuperseded("whisper", active: "parakeet", pending: nil))
    }

    func testSupersededEngineIsKeptWhenSelectionReturnedToIt() {
        XCTAssertFalse(
            EngineSwitch.shouldUnloadSuperseded("whisper", active: "parakeet", pending: "whisper"))
    }

    func testSupersededEngineIsKeptWhenItBecameActive() {
        XCTAssertFalse(
            EngineSwitch.shouldUnloadSuperseded("whisper", active: "whisper", pending: nil))
    }
}

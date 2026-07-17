import XCTest


/// The engine-switch decision rules, including the two bugs they exist to
/// prevent: a switch-back mid-preload being silently ignored (the app would
/// commit to the deselected engine), and a superseded switch leaving its
/// speculatively loaded model resident with no owner.
final class EngineSwitchTests: XCTestCase {
    // MARK: - action(selecting:active:pending:)

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

    /// The mid-preload switch-back: user clicks Whisper, changes their mind,
    /// clicks Parakeet before the preload commits. Comparing against the
    /// stale `active` alone would ignore the click and commit Whisper.
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

    // MARK: - shouldUnloadSuperseded(_:active:pending:)

    /// Rapid A→B→C: the cancelled A→B task must unload B, or it stays
    /// resident with no owner until the idle unloader runs.
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

import CoreAudio
import XCTest

/// The decision table for re-applying the chosen microphone; precedence runs top to bottom of the file.
final class InputRebindTests: XCTestCase {
    private func decide(
        wanted: String? = "usb-mic", resolved: AudioDeviceID? = 42, bound: AudioDeviceID? = 42,
        configurationChanged: Bool = false, lastRebuildTarget: InputRebind.Target? = nil, running: Bool = false
    ) -> InputRebind.Action {
        InputRebind.decide(
            wantedUID: wanted, resolved: resolved, bound: bound,
            configurationChanged: configurationChanged, lastRebuildTarget: lastRebuildTarget, running: running)
    }

    private let rebuiltForUSBMic = InputRebind.Target(uid: "usb-mic", device: 42)

    func testBoundDeviceMatchingTheResolvedOneIsKept() {
        XCTAssertEqual(decide(resolved: 42, bound: 42), .keep)
    }

    func testBoundDeviceDifferingFromTheResolvedOneIsRebuilt() {
        XCTAssertEqual(decide(resolved: 42, bound: 7), .rebuild)
    }

    func testReplugWithANewDeviceIDIsRebuilt() {
        // Same UID, new AudioDeviceID after a reconnect; the engine still holds the old one.
        XCTAssertEqual(decide(resolved: 43, bound: 42), .rebuild)
    }

    func testSecondMismatchForTheTargetOfTheLastRebuildDidNotStick() {
        XCTAssertEqual(
            decide(resolved: 42, bound: 7, lastRebuildTarget: rebuiltForUSBMic),
            .bindingDidNotStick(uid: "usb-mic"))
    }

    func testANewDeviceIDForTheSameUIDIsStillRebuilt() {
        XCTAssertEqual(decide(resolved: 43, bound: 7, lastRebuildTarget: rebuiltForUSBMic), .rebuild)
    }

    func testAnotherUIDWithTheSameDeviceIDIsStillRebuilt() {
        XCTAssertEqual(
            decide(wanted: "headset-mic", resolved: 42, bound: 7, lastRebuildTarget: rebuiltForUSBMic), .rebuild)
    }

    func testConfigurationChangeIsRebuiltEvenAfterABindDidNotStick() {
        XCTAssertEqual(
            decide(resolved: 42, bound: 7, configurationChanged: true, lastRebuildTarget: rebuiltForUSBMic), .rebuild)
    }

    func testMatchingBindingIsKeptWhateverTheLastRebuildTargeted() {
        XCTAssertEqual(decide(resolved: 42, bound: 42, lastRebuildTarget: rebuiltForUSBMic), .keep)
    }

    func testMissingDeviceBeatsTheTargetOfTheLastRebuild() {
        XCTAssertEqual(
            decide(resolved: nil, bound: 7, lastRebuildTarget: rebuiltForUSBMic), .useSystemDefault(missingUID: "usb-mic"))
    }

    func testConfigurationChangeIsRebuiltEvenWhenTheDevicesMatch() {
        XCTAssertEqual(decide(resolved: 42, bound: 42, configurationChanged: true), .rebuild)
    }

    func testMissingDeviceFallsBackToTheSystemDefaultAndNamesTheUID() {
        XCTAssertEqual(decide(resolved: nil, bound: 7), .useSystemDefault(missingUID: "usb-mic"))
    }

    func testConfigurationChangeBeatsAMissingDeviceBecauseTheNewEngineReportsTheMiss() {
        XCTAssertEqual(decide(resolved: nil, bound: 7, configurationChanged: true), .rebuild)
    }

    func testNoPreferredInputIsKept() {
        XCTAssertEqual(decide(wanted: nil, resolved: nil, bound: 7), .keep)
        XCTAssertEqual(decide(wanted: nil, resolved: 42, bound: 7), .keep)
    }

    func testNoPreferredInputStillRebuildsAfterAConfigurationChangeForTheNewFormat() {
        // The system-default engine's tap and converter go stale when the default input changes.
        XCTAssertEqual(decide(wanted: nil, resolved: nil, bound: 7, configurationChanged: true), .rebuild)
    }

    func testUnreadableBoundDeviceIsKeptBecauseARebuildCannotHelp() {
        XCTAssertEqual(decide(resolved: 42, bound: nil), .keep)
    }

    func testRunningDefersEveryRebuild() {
        XCTAssertEqual(decide(resolved: 42, bound: 7, running: true), .deferWhileRunning)
        XCTAssertEqual(decide(resolved: 42, bound: 42, configurationChanged: true, running: true), .deferWhileRunning)
        XCTAssertEqual(decide(wanted: nil, resolved: nil, bound: 7, configurationChanged: true, running: true), .deferWhileRunning)
    }

    func testRunningStillReportsABindThatDidNotStick() {
        XCTAssertEqual(
            decide(resolved: 42, bound: 7, lastRebuildTarget: rebuiltForUSBMic, running: true),
            .bindingDidNotStick(uid: "usb-mic"))
    }

    func testRunningWithNothingToFixIsKept() {
        XCTAssertEqual(decide(resolved: 42, bound: 42, running: true), .keep)
        XCTAssertEqual(decide(wanted: nil, resolved: nil, bound: 7, running: true), .keep)
    }

    func testRunningStillReportsAMissingDevice() {
        XCTAssertEqual(
            decide(resolved: nil, bound: 7, running: true), .useSystemDefault(missingUID: "usb-mic"))
    }
}

import CoreAudio
import XCTest

/// The chosen microphone must be re-applied whenever the engine could have moved off it, but never under a live recording.
/// Drives the real `AVEngineControl` through `Recorder`, with a fake engine that models the device it is bound to.
final class RecorderRebindTests: XCTestCase {
    private let usbMic: AudioDeviceID = 42
    private let headset: AudioDeviceID = 7

    private var devices: [String: AudioDeviceID] = [:]
    private var engines: [FakeCaptureEngine] = []
    private var logs: [String] = []
    /// Applied to every engine made from now on, so a test can fail the bind of a rebuilt engine.
    private var bindStatusForNewEngines: OSStatus = noErr
    /// Applied to every engine made from now on, like `bindStatusForNewEngines`.
    private var postsConfigurationChangeOnBindForNewEngines = false
    private var rebindOnStartForNewEngines: AudioDeviceID?
    private var resolveCalls = 0
    private let didNotStick = "recorder: input usb did not stick; keeping the current engine"
    private let couldNotSelect = "recorder: could not select input device usb: OSStatus -50"
    private var control: AVEngineControl!
    private var recorder: Recorder!

    private var engine: FakeCaptureEngine { engines.last! }

    override func setUp() {
        super.setUp()
        devices = ["usb": usbMic]
        engines = []
        logs = []
        bindStatusForNewEngines = noErr
        postsConfigurationChangeOnBindForNewEngines = false
        rebindOnStartForNewEngines = nil
        resolveCalls = 0
        control = AVEngineControl(
            onLog: { [unowned self] in logs.append($0) },
            resolveDevice: { [unowned self] in
                resolveCalls += 1
                return devices[$0]
            },
            makeEngine: { [unowned self] in
                let fake = FakeCaptureEngine()
                fake.bindStatus = bindStatusForNewEngines
                fake.postsConfigurationChangeOnBind = postsConfigurationChangeOnBindForNewEngines
                fake.rebindOnStart = rebindOnStartForNewEngines
                engines.append(fake)
                return fake
            })
        recorder = Recorder(engineControl: control)
    }

    /// Selects the usb mic and prewarms, as the app does at launch.
    private func chooseUSBMicAndPrewarm() throws {
        recorder.setPreferredInput(uid: "usb")
        try recorder.prewarm()
    }

    private func dictate() throws {
        try recorder.arm()
        _ = recorder.disarm()
    }

    // MARK: first bind

    func testFirstPrewarmBindsTheChosenDeviceOnTheFreshEngineWithoutAnExtraRebuild() throws {
        try chooseUSBMicAndPrewarm()
        XCTAssertEqual(engine.bindRequests, [usbMic])
        XCTAssertEqual(engine.tapInstalls, 1)
        XCTAssertEqual(engines.count, 2, "initial engine, replaced once by the selection")
        try dictate()
        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(logs, [], "a first bind is not a rebind")
    }

    func testNoPreferredInputBindsNothingAndNeverRebuilds() throws {
        try recorder.prewarm()
        try dictate()
        try dictate()
        XCTAssertEqual(engines.count, 1)
        XCTAssertEqual(engine.bindRequests, [])
        XCTAssertEqual(engine.tapInstalls, 1)
        XCTAssertEqual(logs, [])
    }

    // MARK: hypothesis 1 and 3 — the engine moved off the chosen device

    func testEngineMovedOffTheChosenDeviceIsRebuiltOnTheNextArm() throws {
        try chooseUSBMicAndPrewarm()
        let stale = engine
        stale.drift(to: headset)

        try recorder.arm()

        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(stale.stopCalls, 1, "the stale engine is torn down")
        XCTAssertEqual(engine.bindRequests, [usbMic])
        XCTAssertEqual(engine.boundDevice, usbMic)
        XCTAssertEqual(engine.tapInstalls, 1)
        XCTAssertEqual(engine.startCalls, 1)
        XCTAssertEqual(logs, ["recorder: input rebound to usb"])
    }

    func testEngineMovedOffTheChosenDeviceIsRebuiltOnTheNextPrewarmToo() throws {
        try chooseUSBMicAndPrewarm()
        engine.drift(to: headset)

        try recorder.prewarm()

        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(engine.boundDevice, usbMic)
        XCTAssertEqual(engine.prepareCalls, 1)
        XCTAssertEqual(engine.startCalls, 0, "prewarm must not light the mic indicator")
    }

    func testRebuiltEngineDeliversSamplesToTheRecording() throws {
        try chooseUSBMicAndPrewarm()
        engine.drift(to: headset)
        try recorder.arm()
        engine.emit([0.1, 0.2])
        XCTAssertEqual(recorder.disarm(), [0.1, 0.2])
    }

    func testReplugWithANewDeviceIDRebindsToTheNewID() throws {
        try chooseUSBMicAndPrewarm()
        devices["usb"] = 43

        try recorder.arm()

        XCTAssertEqual(engine.bindRequests, [43])
        XCTAssertEqual(logs, ["recorder: input rebound to usb"])
    }

    func testAnEngineStillOnTheChosenDeviceIsNotRebuilt() throws {
        try chooseUSBMicAndPrewarm()
        try dictate()
        try dictate()
        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engine.startCalls, 2)
        XCTAssertEqual(logs, [])
    }

    // MARK: hypothesis 1 — configuration change

    func testConfigurationChangeIsLoggedAndConsumedByTheNextArm() throws {
        try chooseUSBMicAndPrewarm()

        engine.simulateConfigurationChange(movingTo: headset)
        XCTAssertEqual(logs, ["recorder: audio configuration changed"])
        XCTAssertEqual(engines.count, 2, "nothing is rebuilt until the next arm")

        try recorder.arm()
        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(engine.boundDevice, usbMic)
        _ = recorder.disarm()

        try recorder.arm()
        XCTAssertEqual(engines.count, 3, "the flag was consumed")
    }

    func testConfigurationChangeWhileIdleRebuildsEvenIfTheBoundDeviceStillMatches() throws {
        try chooseUSBMicAndPrewarm()

        engine.simulateConfigurationChange(movingTo: usbMic)
        try recorder.arm()

        XCTAssertEqual(engines.count, 3, "the tap format may be stale after a format change")
    }

    func testConfigurationChangeNeverRebuildsMidRecording() throws {
        try chooseUSBMicAndPrewarm()
        try recorder.arm()
        let live = engine

        live.simulateConfigurationChange(movingTo: headset)
        engine.emit([0.5])
        _ = recorder.disarm()

        XCTAssertEqual(engines.count, 2, "no rebuild between arm and disarm")
        XCTAssertEqual(live.stopCalls, 0)

        try recorder.arm()
        XCTAssertEqual(engines.count, 3, "the deferred change is consumed by the next arm")
        XCTAssertEqual(engine.boundDevice, usbMic)
    }

    func testRunningEngineIsNeverRebuiltEvenWhenStartAndPrepareAreCalledDirectly() throws {
        try chooseUSBMicAndPrewarm()
        try control.start()
        engine.drift(to: headset)

        control.prepare()
        try control.start()

        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engine.boundDevice, headset)
    }

    func testConfigurationChangeWithoutAPreferredInputStillRebuildsForTheNewFormat() throws {
        try recorder.prewarm()
        engine.simulateConfigurationChange(movingTo: headset)

        try recorder.arm()

        XCTAssertEqual(engines.count, 2)
        XCTAssertEqual(engine.bindRequests, [])
        XCTAssertEqual(engine.tapInstalls, 1)
        XCTAssertEqual(logs, ["recorder: audio configuration changed"], "nothing was rebound")
    }

    func testRebuiltEngineIsObservedForTheNextConfigurationChange() throws {
        try chooseUSBMicAndPrewarm()
        engine.simulateConfigurationChange()
        try recorder.arm()
        _ = recorder.disarm()

        engine.simulateConfigurationChange()
        try recorder.arm()

        XCTAssertEqual(engines.count, 4)
        XCTAssertEqual(logs.filter { $0 == "recorder: audio configuration changed" }.count, 2)
    }

    // MARK: hypothesis 2 — the device is missing

    func testLookupMissLogsOnceAndLeavesTheEngineOnTheSystemDefault() throws {
        devices = [:]
        try chooseUSBMicAndPrewarm()

        XCTAssertEqual(engine.bindRequests, [])
        XCTAssertEqual(engine.boundDevice, FakeCaptureEngine.systemDefault)
        XCTAssertEqual(logs, ["recorder: input usb not found; using system default"])

        try dictate()
        try dictate()
        XCTAssertEqual(engines.count, 2, "nothing to rebind to")
        XCTAssertEqual(logs.count, 1, "once per engine")
    }

    func testDeviceAppearingAfterAMissIsRebound() throws {
        devices = [:]
        try chooseUSBMicAndPrewarm()

        devices["usb"] = usbMic
        try recorder.arm()

        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(engine.bindRequests, [usbMic])
        XCTAssertEqual(
            logs,
            [
                "recorder: input usb not found; using system default",
                "recorder: input rebound to usb",
            ])
    }

    func testDeviceVanishingAfterAConfigurationChangeIsReportedByTheNewEngine() throws {
        try chooseUSBMicAndPrewarm()
        devices = [:]
        engine.simulateConfigurationChange(movingTo: headset)

        try recorder.arm()

        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(engine.bindRequests, [])
        XCTAssertEqual(
            logs,
            [
                "recorder: audio configuration changed",
                "recorder: input usb not found; using system default",
            ])
    }

    func testMissIsLoggedAgainForEachNewEngine() throws {
        devices = [:]
        try chooseUSBMicAndPrewarm()
        recorder.setPreferredInput(uid: "usb")
        try recorder.prewarm()
        XCTAssertEqual(logs.count, 2)
    }

    func testDeviceVanishingFromAnAlreadyBoundEngineWithoutAConfigurationChangeIsLoggedOnceNotRebuilt() throws {
        try chooseUSBMicAndPrewarm()
        devices = [:]

        try dictate()
        try dictate()

        XCTAssertEqual(engines.count, 2, "only a configuration change rebuilds; the miss is reported")
        XCTAssertEqual(engine.bindRequests, [usbMic])
        XCTAssertEqual(engine.startCalls, 2, "capture still starts")
        XCTAssertEqual(
            logs, ["recorder: input usb not found; keeping the current engine"],
            "once per engine; it stays bound to the vanished device, so the line must not claim the system default")
    }

    // MARK: re-picking

    func testRepickingTheSameInputRebuildsTheEngine() throws {
        try chooseUSBMicAndPrewarm()
        let before = engine
        before.drift(to: headset)

        recorder.setPreferredInput(uid: "usb")

        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(before.stopCalls, 1)

        try recorder.prewarm()
        XCTAssertEqual(engine.bindRequests, [usbMic])
        XCTAssertEqual(engine.tapInstalls, 1)
        XCTAssertEqual(logs, [], "the coordinator logs the selection, not the recorder")
    }

    func testSwitchingToSystemDefaultRebuildsAndBindsNothing() throws {
        try chooseUSBMicAndPrewarm()
        recorder.setPreferredInput(uid: nil)
        try recorder.prewarm()
        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(engine.bindRequests, [])
    }

    // MARK: a bind that does not stick is tried once

    func testABindThatAlwaysFailsRebuildsOnceAndThenKeepsTheEngine() throws {
        bindStatusForNewEngines = -50
        try chooseUSBMicAndPrewarm()

        for _ in 0..<4 { try dictate() }

        XCTAssertEqual(engines.count, 3, "the initial engine, the selection's, and exactly one rebuild")
        XCTAssertEqual(engine.startCalls, 4, "capture still starts every time")
        XCTAssertEqual(logs, [couldNotSelect, couldNotSelect, didNotStick])
    }

    func testAnEngineThatRebindsItselfOnEveryStartIsRebuiltOnceAndThenKept() throws {
        rebindOnStartForNewEngines = headset
        try chooseUSBMicAndPrewarm()

        for _ in 0..<5 { try dictate() }

        XCTAssertEqual(engines.count, 3, "the initial engine, the selection's, and exactly one rebuild")
        XCTAssertEqual(logs, ["recorder: input rebound to usb", didNotStick])
    }

    func testANewDeviceIDForTheSameInputStillRebuildsAfterABindDidNotStick() throws {
        bindStatusForNewEngines = -50
        try chooseUSBMicAndPrewarm()
        try dictate()
        try dictate()
        XCTAssertEqual(engines.count, 3)

        devices["usb"] = 43
        try dictate()

        XCTAssertEqual(engines.count, 4)
        XCTAssertEqual(engine.bindRequests, [43])
    }

    func testAConfigurationChangeStillRebuildsOnceAfterABindDidNotStick() throws {
        bindStatusForNewEngines = -50
        try chooseUSBMicAndPrewarm()
        try dictate()
        try dictate()
        XCTAssertEqual(engines.count, 3)

        engine.simulateConfigurationChange()
        for _ in 0..<3 { try dictate() }

        XCTAssertEqual(engines.count, 4, "one rebuild for the change, none for the dictations after it")
        XCTAssertEqual(
            logs,
            [
                couldNotSelect,
                couldNotSelect,
                didNotStick,
                "recorder: audio configuration changed",
                couldNotSelect,
                didNotStick,
            ])
    }

    func testAConfigurationChangeFromAGoodBindingIsRebuiltOnceWhenItsBindDoesNotStick() throws {
        try chooseUSBMicAndPrewarm()
        bindStatusForNewEngines = -50

        engine.simulateConfigurationChange()
        for _ in 0..<3 { try dictate() }

        XCTAssertEqual(engines.count, 3, "the initial engine, the selection's, and exactly one rebuild")
        XCTAssertEqual(logs, ["recorder: audio configuration changed", couldNotSelect, didNotStick])
    }

    func testSelectingTheInputAgainEarnsAnotherRebuildAfterABindDidNotStick() throws {
        bindStatusForNewEngines = -50
        try chooseUSBMicAndPrewarm()
        try dictate()
        try dictate()
        XCTAssertEqual(engines.count, 3)

        recorder.setPreferredInput(uid: "usb")
        try dictate()
        try dictate()

        XCTAssertEqual(engines.count, 5, "the new selection's engine, then one rebuild")
    }

    func testDriftingAgainAfterABindThatStuckIsRebuiltAgain() throws {
        try chooseUSBMicAndPrewarm()
        engine.drift(to: headset)
        try dictate()
        try dictate()
        engine.drift(to: headset)
        try dictate()

        XCTAssertEqual(engines.count, 4, "the first rebuild stuck, so the second drift is a new problem")
        XCTAssertEqual(engine.boundDevice, usbMic)
        XCTAssertFalse(logs.contains(didNotStick))
    }

    // MARK: the configuration change our own bind posts

    func testTheConfigurationChangeOurOwnFirstBindPostsDoesNotRebuildTheNextArm() throws {
        postsConfigurationChangeOnBindForNewEngines = true
        try chooseUSBMicAndPrewarm()
        XCTAssertEqual(logs, ["recorder: audio configuration changed"], "still logged: it is a fact worth seeing")

        try dictate()
        try dictate()

        XCTAssertEqual(engines.count, 2)
    }

    func testTheConfigurationChangeOurOwnRebuildBindPostsDoesNotRebuildTheNextArm() throws {
        try chooseUSBMicAndPrewarm()
        postsConfigurationChangeOnBindForNewEngines = true
        engine.drift(to: headset)

        try dictate()
        try dictate()
        try dictate()

        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(logs, ["recorder: audio configuration changed", "recorder: input rebound to usb"])
    }

    // MARK: one device lookup per start

    func testAFirstBindResolvesTheChosenDeviceOnce() throws {
        recorder.setPreferredInput(uid: "usb")
        resolveCalls = 0

        try recorder.prewarm()

        XCTAssertEqual(resolveCalls, 1)
    }

    func testARebuildResolvesTheChosenDeviceOnce() throws {
        try chooseUSBMicAndPrewarm()
        engine.drift(to: headset)
        resolveCalls = 0

        try recorder.arm()

        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(resolveCalls, 1, "the id that was compared is the id that is bound")
    }

    // MARK: failures worth a log line

    func testFailedBindIsLoggedAndCaptureStillStarts() throws {
        recorder.setPreferredInput(uid: "usb")
        engine.bindStatus = -50

        try recorder.arm()

        XCTAssertEqual(logs, ["recorder: could not select input device usb: OSStatus -50"])
        XCTAssertEqual(engine.startCalls, 1)
    }

    func testFailedBindOnARebuiltEngineIsNotAnnouncedAsARebind() throws {
        try chooseUSBMicAndPrewarm()
        engine.drift(to: headset)
        bindStatusForNewEngines = -50

        try recorder.arm()

        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(logs, ["recorder: could not select input device usb: OSStatus -50"])
    }

    func testStartFailureIsSurfacedWithTheEngineError() {
        recorder.setPreferredInput(uid: nil)
        engine.startError = TestError(message: "no input")
        XCTAssertThrowsError(try recorder.arm()) { error in
            XCTAssertTrue((error as? RecorderError)?.message.contains("no input") == true)
        }
    }

    // MARK: hypothesis 4 — converter errors

    func testFirstConversionErrorPerEngineIsLogged() throws {
        try chooseUSBMicAndPrewarm()
        try recorder.arm()

        engine.failConversion("format mismatch")
        engine.failConversion("format mismatch")
        engine.failConversion("other")

        XCTAssertEqual(logs, ["recorder: audio conversion failed: format mismatch"])
    }

    func testConversionErrorIsLoggedAgainAfterARebuild() throws {
        try chooseUSBMicAndPrewarm()
        try recorder.arm()
        engine.failConversion("first")
        _ = recorder.disarm()

        engine.drift(to: headset)
        try recorder.arm()
        engine.failConversion("second")

        XCTAssertEqual(
            logs,
            [
                "recorder: audio conversion failed: first",
                "recorder: input rebound to usb",
                "recorder: audio conversion failed: second",
            ])
    }
}

import AppKit
import XCTest

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    private var recorder: FakeRecorder!
    private var monitor: FakeHotkeyMonitor!
    private var notifier: FakeNotifier!
    private var sounds: Box<String>!
    private var logs: Box<String>!
    private var inputMonitoring: Box<Bool>!
    private var soundsEnabled = true
    private var microphoneGranted = true
    private var sinks: PipelineSinks!
    private var monitorDown: (() -> Void)!
    private var monitorUp: (() -> Void)!
    private var pipelineClock: FakeClock!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        recorder = FakeRecorder()
        monitor = FakeHotkeyMonitor()
        notifier = FakeNotifier()
        sounds = Box<String>()
        logs = Box<String>()
        inputMonitoring = Box<Bool>()
        soundsEnabled = true
        microphoneGranted = true
        pipelineClock = FakeClock()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func make(
        config: PipelineConfig = PipelineConfig(),
        errorStickySeconds: Double = 5,
        hintSeconds: Double = 4,
        failedAudioURL: URL? = nil
    ) -> DictationCoordinator {
        let recorder = self.recorder!
        let clock = pipelineClock!
        return DictationCoordinator(
            recorder: recorder,
            pipelineConfig: config,
            hotkey: .rightOption,
            makePipeline: { [unowned self] sinks in
                self.sinks = sinks
                return DictationPipeline(
                    recorder: recorder, stt: FakeStt(), cleaner: FakeCleaner(), paster: FakePaster(),
                    history: History(maxLen: 10), config: config, clock: { clock.t },
                    runner: { _ in },  // jobs are not under test here: a held key is discarded or force-stopped
                    onState: sinks.onState, onNotice: sinks.onNotice, saveFailedAudio: sinks.saveFailedAudio,
                    onHint: sinks.onHint, onPasted: sinks.onPasted)
            },
            makeHotkeyMonitor: { [unowned self] down, up in
                self.monitorDown = down
                self.monitorUp = up
                return self.monitor
            },
            notifier: notifier,
            playSound: { [unowned self] in sounds.append($0) },
            soundsEnabled: { [unowned self] in soundsEnabled },
            microphoneGranted: { [unowned self] in microphoneGranted },
            reportInputMonitoring: { [unowned self] in inputMonitoring.append($0) },
            errorStickySeconds: errorStickySeconds,
            hintSeconds: hintSeconds,
            failedAudioURL: failedAudioURL ?? directory.appendingPathComponent("last_failed.wav"),
            log: { [logs] in logs!.append($0) })
    }

    // MARK: - State, error stickiness and sounds

    func testErrorIsStickyThenRevertsToIdle() async {
        let c = make(errorStickySeconds: 0.05)

        c.applyState(.error)
        XCTAssertEqual(c.state, .error)

        let reverted = await eventually { c.state == .idle }
        XCTAssertTrue(reverted)
    }

    func testANewerStateCancelsTheErrorRevert() async {
        let c = make(errorStickySeconds: 0.05)
        c.applyState(.error)
        let revert = c.errorRevert

        c.applyState(.recording)
        await revert?.value

        XCTAssertEqual(c.state, .recording)
    }

    func testRecordingPlaysPopAndErrorPlaysBasso() {
        let c = make()

        c.applyState(.recording)
        c.applyState(.processing)
        c.applyState(.idle)
        c.applyState(.error)

        XCTAssertEqual(sounds.value, ["Pop", "Basso"])
    }

    func testNoSoundsWhenDisabled() {
        soundsEnabled = false
        let c = make()

        c.applyState(.recording)
        c.applyState(.error)

        XCTAssertEqual(sounds.value, [])
        XCTAssertEqual(c.state, .error)
    }

    func testPipelineStateReachesThePublishedState() async {
        let c = make()

        c.handleKeyDown()

        let recording = await eventually { c.state == .recording }
        XCTAssertTrue(recording)
        XCTAssertEqual(sounds.value, ["Pop"])
    }

    // MARK: - Hints and the paste cue

    func testHintReachesThePublishedStateThenClearsAfterHintSeconds() async {
        let c = make(hintSeconds: 0.05)

        sinks.onHint("Pasted raw — cleanup timed out")

        let shown = await eventually { c.hint == "Pasted raw — cleanup timed out" }
        XCTAssertTrue(shown)
        let cleared = await eventually { c.hint == nil }
        XCTAssertTrue(cleared)
    }

    func testHintStaysUntilItsWindowEnds() async {
        let c = make(hintSeconds: 30)

        c.showHint("Pasted raw — cleanup failed")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(c.hint, "Pasted raw — cleanup failed")
    }

    func testANewerHintReplacesTheOldOneAndCancelsItsClear() {
        let c = make(hintSeconds: 30)
        c.showHint("first")
        let firstClear = c.hintClear

        c.showHint("second")

        XCTAssertEqual(firstClear?.isCancelled, true)
        XCTAssertEqual(c.hint, "second")
    }

    func testKeyDownClearsTheHint() {
        let c = make()
        c.showHint("Pasted raw — cleanup failed")
        let clear = c.hintClear

        c.handleKeyDown()

        XCTAssertNil(c.hint)
        XCTAssertEqual(clear?.isCancelled, true)
    }

    func testNoSpeechHeardWithTheMicrophoneGrantedShowsTheHint() {
        let c = make()

        c.showHint("No speech heard")

        XCTAssertEqual(c.hint, "No speech heard")
        XCTAssertEqual(notifier.delivered.count, 0)
    }

    func testNoSpeechHeardWithoutTheMicrophoneNotifiesInsteadOfHinting() async {
        microphoneGranted = false
        let c = make()

        sinks.onHint("No speech heard")

        let delivered = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(delivered)
        XCTAssertEqual(notifier.delivered.first?.title, "scribe")
        XCTAssertEqual(notifier.delivered.first?.body, "Microphone is off — open Setup / Doctor…")
        XCTAssertNil(c.hint)
    }

    func testOtherHintsStillShowWithoutTheMicrophone() {
        microphoneGranted = false
        let c = make()

        c.showHint("Pasted raw — cleanup timed out")

        XCTAssertEqual(c.hint, "Pasted raw — cleanup timed out")
        XCTAssertEqual(notifier.delivered.count, 0)
    }

    func testPasteCuePlaysTinkWhenSoundsAreOn() async {
        let c = make()
        _ = c

        sinks.onPasted()

        let played = await eventually { sounds.value == ["Tink"] }
        XCTAssertTrue(played)
    }

    func testPasteCueIsSilentWhenSoundsAreOff() {
        soundsEnabled = false
        let c = make()

        c.playPasteCue()

        XCTAssertEqual(sounds.value, [])
    }

    // MARK: - Notifications

    func testNoticeFromThePipelineIsDeliveredUnderTheScribeTitle() async {
        let c = make()
        _ = c

        sinks.onNotice("hello")

        let delivered = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(delivered)
        XCTAssertEqual(notifier.delivered.first?.title, "scribe")
        XCTAssertEqual(notifier.delivered.first?.body, "hello")
    }

    func testNotifyLogsADeliveryFailure() {
        notifier.deliveryError = TestError(message: "denied")
        let c = make()

        c.notify("hello")

        XCTAssertEqual(logs.value, ["notification delivery failed: hello (denied)"])
    }

    func testRecordingFailureSurfacesAsANotification() async {
        recorder = FakeRecorder(armError: TestError(message: "no mic"))
        let c = make()

        c.handleKeyDown()

        let delivered = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(delivered)
        XCTAssertEqual(notifier.delivered.first?.body, "Failed to start recording: no mic")
    }

    // MARK: - Failed audio

    func testFailedAudioIsWrittenAsAWav() async {
        let c = make()
        _ = c

        sinks.saveFailedAudio([0.1, -0.1, 0.2])

        let url = directory.appendingPathComponent("last_failed.wav")
        let written = await eventually { FileManager.default.fileExists(atPath: url.path) }
        XCTAssertTrue(written)
        XCTAssertEqual((try? Data(contentsOf: url))?.count, 44 + 3 * 2)
    }

    func testFailedAudioWriteErrorIsLogged() {
        let c = make(failedAudioURL: URL(fileURLWithPath: "/dev/null/last_failed.wav"))

        c.saveFailedAudio([0.1])

        XCTAssertEqual(logs.value.count, 1)
        XCTAssertTrue(logs.value[0].hasPrefix("failed to save failed-audio wav:"))
    }

    // MARK: - Startup and hotkey install

    func testStartPrewarmsInstallsTheTapAndAsksForNotificationAuthorization() {
        let c = make()

        c.start()

        XCTAssertEqual(recorder.prewarmCalls, 1)
        XCTAssertEqual(monitor.installCalls, 1)
        XCTAssertEqual(notifier.authorizationRequests, 1)
        XCTAssertEqual(inputMonitoring.value, [true])
        XCTAssertTrue(logs.value.contains("hotkey installed (key=right_option)"))
    }

    func testInstallFailureReportsInputMonitoringOff() {
        monitor.installError = HotkeyError(message: "denied")
        let c = make()

        c.start()

        XCTAssertEqual(inputMonitoring.value, [false])
        XCTAssertTrue(logs.value.contains { $0.hasPrefix("hotkey install failed:") })
        XCTAssertFalse(logs.value.contains { $0.hasPrefix("hotkey installed") })
    }

    func testModifierEventsAreLogged() {
        let c = make()
        c.start()

        monitor.onModifierEvent?("flagsChanged keycode=61")

        XCTAssertTrue(logs.value.contains("tap: flagsChanged keycode=61"))
    }

    func testActivateHotkeyReinstallsAndReportsSuccess() {
        let c = make()

        c.activateHotkeyIfNeeded()

        XCTAssertEqual(monitor.reinstallCalls, 1)
        XCTAssertEqual(inputMonitoring.value, [true])
    }

    func testActivateHotkeyReportsFailureAndLogsIt() {
        monitor.reinstallError = HotkeyError(message: "still denied")
        let c = make()

        c.activateHotkeyIfNeeded()

        XCTAssertEqual(inputMonitoring.value, [false])
        XCTAssertTrue(logs.value.contains { $0.hasPrefix("hotkey reinstall failed:") })
    }

    // MARK: - Key handling and the hold watchdog

    func testKeyDownRunsTheHookBeforeRecordingStarts() {
        let c = make()
        var armedWhenHookRan: Bool?
        c.onKeyDown = { [unowned self] in armedWhenHookRan = recorder.armed }

        c.handleKeyDown()

        XCTAssertEqual(armedWhenHookRan, false)
        XCTAssertTrue(recorder.armed)
        XCTAssertNotNil(c.holdWatchdog)
    }

    func testMonitorCallbacksDriveTheKeyHandlers() {
        let c = make()
        var hookCalls = 0
        c.onKeyDown = { hookCalls += 1 }

        monitorDown()
        XCTAssertEqual(hookCalls, 1)
        XCTAssertTrue(recorder.armed)

        monitorUp()
        XCTAssertFalse(recorder.armed)
    }

    func testKeyUpCancelsTheWatchdog() async {
        let c = make(config: PipelineConfig(maxHold: 0.05))
        c.handleKeyDown()
        let watchdog = c.holdWatchdog

        c.handleKeyUp()
        await watchdog?.value

        XCTAssertEqual(monitor.forgetCalls, 0)
        XCTAssertFalse(recorder.armed)
    }

    func testWatchdogForceStopsAHoldThatNeverEnds() async {
        let c = make(config: PipelineConfig(maxHold: 0.05))

        c.handleKeyDown()

        let forgot = await eventually { monitor.forgetCalls == 1 }
        XCTAssertTrue(forgot)
        XCTAssertFalse(recorder.armed)
        let notified = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(notified)
        XCTAssertEqual(notifier.delivered.first?.body, "Stopped after 0 min — release the key")
    }

    func testASecondKeyDownReplacesTheWatchdog() async {
        let c = make(config: PipelineConfig(maxHold: 60))
        c.handleKeyDown()
        let first = c.holdWatchdog

        c.handleKeyDown()
        await first?.value

        XCTAssertEqual(first?.isCancelled, true)
        XCTAssertEqual(monitor.forgetCalls, 0, "the replaced watchdog must not fire")
        c.handleKeyUp()
    }

    func testSleepCancelsTheHoldAndForgetsTheKey() async {
        let c = make()
        c.start()
        c.handleKeyDown()
        let watchdog = c.holdWatchdog
        XCTAssertTrue(recorder.armed)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        let forgot = await eventually { monitor.forgetCalls >= 1 }
        XCTAssertTrue(forgot)
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(watchdog?.isCancelled, true)
    }

    // MARK: - Recorder prewarm and microphone

    func testPrewarmIsANoOpWithoutTheMicrophoneGrant() {
        microphoneGranted = false
        let c = make()

        c.prewarmRecorderIfGranted()

        XCTAssertEqual(recorder.prewarmCalls, 0)
        XCTAssertEqual(logs.value, [])
    }

    func testPrewarmRunsWhenGrantedAndLogsIt() {
        let c = make()

        c.prewarmRecorderIfGranted()

        XCTAssertEqual(recorder.prewarmCalls, 1)
        XCTAssertEqual(logs.value, ["recorder prewarmed"])
    }

    func testPrewarmFailureIsNonFatalAndLogged() {
        recorder.prewarmError = TestError(message: "engine busy")
        let c = make()

        c.prewarmRecorderIfGranted()

        XCTAssertEqual(logs.value, ["recorder prewarm failed: engine busy"])
    }

    func testSelectMicrophoneSetsTheInputThenPrewarms() {
        let c = make()

        c.selectMicrophone(uid: "usb-1")
        c.selectMicrophone(uid: nil)

        XCTAssertEqual(recorder.preferredInputs, ["usb-1", nil])
        XCTAssertEqual(recorder.prewarmCalls, 2)
        XCTAssertEqual(
            logs.value.filter { $0.hasPrefix("microphone set to") },
            ["microphone set to usb-1", "microphone set to system default"])
    }

    func testSetCleanupEnabledReachesThePipeline() {
        let c = make()
        XCTAssertTrue(c.pipeline.cleanupEnabled)

        c.setCleanupEnabled(false)

        XCTAssertFalse(c.pipeline.cleanupEnabled)
    }
}

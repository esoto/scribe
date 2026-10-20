import AppKit
import XCTest

@MainActor
final class DictationCoordinatorTests: XCTestCase {
    private var recorder: FakeRecorder!
    private var monitor: FakeHotkeyMonitor!
    /// Every monitor the factory built, in order; the first is `monitor`.
    private var monitors: [FakeHotkeyMonitor] = []
    private var monitorKeys: [HotKey] = []
    private var journal: Box<String>!
    private var jobs: Box<String>!
    /// Applied to monitors built after the first, i.e. by `setHotkey`.
    private var rebuiltInstallError: Error?
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
        monitors = []
        monitorKeys = []
        journal = Box<String>()
        jobs = Box<String>()
        rebuiltInstallError = nil
        notifier = FakeNotifier()
        sounds = Box<String>()
        logs = Box<String>()
        inputMonitoring = Box<Bool>()
        soundsEnabled = true
        microphoneGranted = true
        pipelineClock = FakeClock()
        repasted = []
        repasteError = nil
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var repasted: [String] = []
    private var repasteError: Error?

    private func make(
        config: PipelineConfig = PipelineConfig(),
        errorStickySeconds: Double = 5,
        hintSeconds: Double = 4,
        failedAudioURL: URL? = nil
    ) -> DictationCoordinator {
        let recorder = self.recorder!
        let clock = pipelineClock!
        let jobs = self.jobs!
        return DictationCoordinator(
            recorder: recorder,
            pipelineConfig: config,
            hotkey: .rightOption,
            makePipeline: { [unowned self] sinks in
                self.sinks = sinks
                return DictationPipeline(
                    recorder: recorder, stt: FakeStt(), cleaner: FakeCleaner(), paster: FakePaster(),
                    history: History(maxLen: 10), config: config, clock: { clock.t },
                    runner: { _ in jobs.append("job") },  // queued, never run: only whether a hold produced one matters
                    onState: sinks.onState, onNotice: sinks.onNotice, saveFailedAudio: sinks.saveFailedAudio,
                    onHint: sinks.onHint, onPasted: sinks.onPasted)
            },
            makeHotkeyMonitor: { [unowned self] key, down, up in
                self.monitorKeys.append(key)
                self.monitorDown = down
                self.monitorUp = up
                let built: FakeHotkeyMonitor
                if self.monitors.isEmpty {
                    built = self.monitor
                } else {
                    built = FakeHotkeyMonitor()
                    built.installError = self.rebuiltInstallError
                }
                built.name = "monitor\(self.monitors.count)"
                built.journal = self.journal
                self.monitors.append(built)
                return built
            },
            notifier: notifier,
            playSound: { [unowned self] in sounds.append($0) },
            soundsEnabled: { [unowned self] in soundsEnabled },
            microphoneGranted: { [unowned self] in microphoneGranted },
            reportInputMonitoring: { [unowned self] in inputMonitoring.append($0) },
            errorStickySeconds: errorStickySeconds,
            hintSeconds: hintSeconds,
            failedAudioURL: failedAudioURL ?? directory.appendingPathComponent("last_failed.wav"),
            repaste: { [unowned self] text in
                if let repasteError { throw repasteError }
                repasted.append(text)
            },
            repasteDelay: 0,
            log: { [logs] in logs!.append($0) })
    }

    // MARK: - Paste Again

    func testPasteAgainGoesThroughTheGuardedPasteAndPlaysTheCue() async {
        let c = make()
        c.pasteAgain("hello again")
        let done = await eventually { [unowned self] in repasted == ["hello again"] }
        XCTAssertTrue(done)
        XCTAssertEqual(sounds.value, ["Tink"])
        XCTAssertEqual(notifier.delivered.count, 0)
    }

    func testPasteAgainGuardFailureBecomesItsNotice() async {
        repasteError = PasteGuardError(notice: "Accessibility is off — text copied, press ⌘V")
        let c = make()
        c.pasteAgain("hello again")
        let notified = await eventually { [unowned self] in notifier.delivered.count == 1 }
        XCTAssertTrue(notified)
        XCTAssertEqual(notifier.delivered.first?.body, "Accessibility is off — text copied, press ⌘V")
        XCTAssertEqual(sounds.value, [])
    }

    func testPasteAgainOtherFailureIsLoggedAndAsksForManualPaste() async {
        repasteError = TestError(message: "no event")
        let c = make()
        c.pasteAgain("hello again")
        let notified = await eventually { [unowned self] in notifier.delivered.count == 1 }
        XCTAssertTrue(notified)
        XCTAssertEqual(notifier.delivered.first?.body, "Paste failed — press ⌘V to paste manually")
        XCTAssertTrue(logs.value.contains { $0.hasPrefix("paste again failed:") })
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

    func testLastNoticeIsNilAtStart() {
        XCTAssertNil(make().lastNotice)
    }

    func testNotifyRecordsTheTextAndWhenItWasRaised() throws {
        let c = make()
        let before = Date()

        c.notify("Failed to start recording: no mic")

        let notice = try XCTUnwrap(c.lastNotice)
        XCTAssertEqual(notice.text, "Failed to start recording: no mic")
        XCTAssertTrue(notice.at >= before && notice.at <= Date())
    }

    func testASecondNoticeReplacesTheFirst() {
        let c = make()

        c.notify("first")
        c.notify("second")

        XCTAssertEqual(c.lastNotice?.text, "second")
    }

    func testNoticeFromThePipelineIsRecorded() async {
        let c = make()

        sinks.onNotice("Transcription failed")

        let recorded = await eventually { c.lastNotice?.text == "Transcription failed" }
        XCTAssertTrue(recorded)
    }

    func testLastNoticeIsRecordedEvenWhenDeliveryFails() {
        notifier.deliveryError = TestError(message: "denied")
        let c = make()

        c.notify("hello")

        XCTAssertEqual(c.lastNotice?.text, "hello")
    }

    func testGoodNewsIsDeliveredButDoesNotReplaceTheLastProblem() {
        let c = make()

        c.notify("Transcription failed")
        c.notify("Gemma 4 E4B is ready.", kind: .info)

        XCTAssertEqual(c.lastNotice?.text, "Transcription failed")
        XCTAssertEqual(notifier.delivered.map { $0.body }, ["Transcription failed", "Gemma 4 E4B is ready."])
    }

    func testGoodNewsAloneLeavesTheSessionQuiet() {
        let c = make()

        c.notify("Gemma 4 E4B is ready.", kind: .info)

        XCTAssertNil(c.lastNotice)
    }

    func testRecordingFailureSurfacesAsANotification() async {
        recorder = FakeRecorder(armError: TestError(message: "no mic"))
        let c = make()

        c.handleKeyDown()

        let delivered = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(delivered)
        XCTAssertEqual(notifier.delivered.first?.body, UserFacingError.recordingNotice(error: "no mic"))
        XCTAssertFalse(notifier.delivered.first?.body.contains("no mic") ?? true, "the raw error stays out of the notification")
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

    func testStartPrewarmsAndInstallsTheTap() {
        let c = make()

        c.start()

        XCTAssertEqual(recorder.prewarmCalls, 1)
        XCTAssertEqual(monitor.installCalls, 1)
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

    // MARK: - Changing the hotkey at runtime

    func testSetHotkeyUninstallsTheOldTapBeforeInstallingTheNewOne() {
        let c = make()
        c.start()

        c.setHotkey(.f13)

        XCTAssertEqual(monitorKeys, [.rightOption, .f13])
        XCTAssertEqual(c.hotkey, .f13)
        XCTAssertEqual(journal.value, ["monitor0:install", "monitor0:uninstall", "monitor1:install"])
        XCTAssertEqual(inputMonitoring.value, [true, true])
        XCTAssertTrue(logs.value.contains("hotkey changed to f13"))
    }

    func testSetHotkeyRewiresTheKeyHandlersAndTheModifierLog() {
        let c = make()
        c.start()
        c.setHotkey(.f13)
        var hookCalls = 0
        c.onKeyDown = { hookCalls += 1 }

        monitorDown()
        XCTAssertEqual(hookCalls, 1)
        XCTAssertTrue(recorder.armed)
        monitorUp()
        XCTAssertFalse(recorder.armed)

        monitors[1].onModifierEvent?("flagsChanged keycode=105")
        XCTAssertTrue(logs.value.contains("tap: flagsChanged keycode=105"))
    }

    func testSetHotkeyEndsAHoldInProgress() async {
        let c = make()
        c.start()
        c.handleKeyDown()
        let recording = await eventually { c.state == .recording }
        XCTAssertTrue(recording)
        let watchdog = c.holdWatchdog

        c.setHotkey(.f13)

        XCTAssertFalse(recorder.armed, "the swap itself ends the hold")
        XCTAssertEqual(watchdog?.isCancelled, true)
        let idle = await eventually { c.state == .idle }
        XCTAssertTrue(idle)

        pipelineClock.t = 1.0  // past the 0.3 s threshold: a release still reaching an armed pipeline queues a job
        c.handleKeyUp()  // the old key's release, arriving late
        XCTAssertEqual(jobs.value, [], "a hold cut off by the swap must not become a dictation")
    }

    func testSetHotkeyReportsInputMonitoringOffWhenTheNewTapFails() {
        rebuiltInstallError = HotkeyError(message: "denied")
        let c = make()
        c.start()

        c.setHotkey(.f13)

        XCTAssertEqual(inputMonitoring.value, [true, false])
        XCTAssertTrue(logs.value.contains { $0.hasPrefix("hotkey install failed:") })
        XCTAssertTrue(logs.value.contains("hotkey changed to f13"))
    }

    func testTheRetryAfterAFailedSwapRebuildsTheNewKeysTap() {
        rebuiltInstallError = HotkeyError(message: "denied")
        let c = make()
        c.start()
        c.setHotkey(.f13)

        c.activateHotkeyIfNeeded()

        XCTAssertEqual(monitors[0].reinstallCalls, 0)
        XCTAssertEqual(monitors[1].reinstallCalls, 1)
    }

    func testTheWatchdogAfterASwapForgetsTheNewMonitorsKey() async {
        let c = make(config: PipelineConfig(maxHold: 0.05))
        c.start()
        c.setHotkey(.f13)

        c.handleKeyDown()

        let forgot = await eventually { monitors[1].forgetCalls == 1 }
        XCTAssertTrue(forgot)
        XCTAssertEqual(monitors[0].forgetCalls, 0)
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

    func testSetEnhanceAudioEnabledReachesThePipeline() {
        let c = make()
        XCTAssertFalse(c.pipeline.enhanceAudioEnabled)

        c.setEnhanceAudioEnabled(true)

        XCTAssertTrue(c.pipeline.enhanceAudioEnabled)
    }
}

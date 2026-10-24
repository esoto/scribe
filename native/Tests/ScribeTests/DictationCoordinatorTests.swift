import AppKit
import Combine
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
    private var hud: HUDModel!
    private var hudEnabled = true
    private var sinks: PipelineSinks!
    private var monitorDown: ((Bool) -> Void)!
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
        hud = HUDModel()
        hudEnabled = true
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
        failedAudioURL: URL? = nil,
        repasteDelay: Double = 0,
        hudResultSeconds: Double = HUDModel.resultSeconds,
        holdThreshold: Double? = 0.05,
        hotkeyMode: HotkeyMode = .hold,
        latchMaxSeconds: Double = 240
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
            repasteDelay: repasteDelay,
            hud: hud,
            hudEnabled: { [unowned self] in hudEnabled },
            hudResultSeconds: hudResultSeconds,
            holdThreshold: holdThreshold,
            hotkeyMode: hotkeyMode,
            latchMaxSeconds: latchMaxSeconds,
            // The pipeline's clock too: a tap's length and the pipeline's discard of it then agree.
            now: { clock.t },
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
        XCTAssertEqual(sounds.value, [])
    }

    func testPasteAgainWaitsForTheMenuToCloseBeforePasting() async {
        let c = make(repasteDelay: 0.3)
        c.pasteAgain("later")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(repasted, [])
        let done = await eventually { [unowned self] in repasted == ["later"] }
        XCTAssertTrue(done)
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

    // MARK: - Recording pill

    func testPillFollowsTheDictationStates() async {
        let c = make(hudResultSeconds: 0.05)

        c.applyState(.recording)
        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
        c.applyState(.processing)
        XCTAssertEqual(hud.phase, .processing)
        c.playPasteCue()
        XCTAssertEqual(hud.phase, .result("Pasted"))
        c.applyState(.idle)
        XCTAssertEqual(hud.phase, .result("Pasted"))

        let hidden = await eventually { [unowned self] in hud.phase == .hidden }
        XCTAssertTrue(hidden)
    }

    func testAQueuedJobsStartTakesThePillBackFromTheVerdictAhead() {
        let c = make()
        c.applyState(.recording)
        c.applyState(.processing)       // the queued release
        c.playPasteCue()                // the job ahead pasted; its own .idle is suppressed
        XCTAssertEqual(hud.phase, .result("Pasted"))

        c.applyState(.processing)       // the queued job starts

        XCTAssertEqual(hud.phase, .processing)
    }

    func testPillShowsTheRawVerdict() {
        let c = make()

        c.applyState(.recording)
        c.applyState(.processing)
        c.showHint("Pasted raw — cleanup timed out")

        XCTAssertEqual(hud.phase, .result("Pasted raw — cleanup timed out"))
    }

    func testPillHidesAtOnceWhenIdleHasNoVerdict() {
        let c = make()

        c.applyState(.recording)
        c.applyState(.processing)
        c.applyState(.idle)

        XCTAssertEqual(hud.phase, .hidden)
    }

    func testPillOffNeverShows() {
        hudEnabled = false
        let c = make()

        c.applyState(.recording)
        XCTAssertEqual(hud.phase, .hidden)
        XCTAssertNil(c.hudShow, "nothing is scheduled with the pill off")
        c.applyState(.processing)
        XCTAssertEqual(hud.phase, .hidden)
        c.showHint("x")
        XCTAssertEqual(hud.phase, .hidden)
    }

    func testErrorShowsOnThePillThenHides() async {
        let c = make(hudResultSeconds: 0.05)

        c.applyState(.error)
        XCTAssertEqual(hud.phase, .problem("Error — check log"))

        let hidden = await eventually { [unowned self] in hud.phase == .hidden }
        XCTAssertTrue(hidden)
    }

    func testIdleAfterAnErrorLeavesTheProblemUpBriefly() {
        let c = make()

        c.applyState(.error)
        c.applyState(.idle)

        XCTAssertEqual(hud.phase, .problem("Error — check log"))
    }

    func testTurningThePillOffHidesIt() async {
        let c = make()
        c.applyState(.recording)
        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)

        c.setHudEnabled(false)

        XCTAssertEqual(hud.phase, .hidden)
    }

    func testLevelReachesThePillOnlyWhileListening() async {
        let c = make()

        c.reportLevel(rms: 0.1)
        XCTAssertEqual(hud.level, 0)
        c.applyState(.recording)
        c.reportLevel(rms: 0.1)
        XCTAssertEqual(hud.level, 0, "levels before the pill shows are dropped")
        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
        c.reportLevel(rms: 0.1)

        XCTAssertGreaterThan(hud.level, 0)
    }

    func testAnEarlierJobsVerdictLeavesTheHoldInProgressListening() async {
        let c = make()
        c.applyState(.recording)
        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)

        c.playPasteCue()
        c.showHint("Pasted raw — cleanup timed out")
        c.reportLevel(rms: 0.1)

        XCTAssertEqual(hud.phase, .listening)
        XCTAssertGreaterThan(hud.level, 0)
    }

    func testANewHoldCancelsThePendingHide() async {
        let c = make()
        c.applyState(.processing)
        c.playPasteCue()
        c.applyState(.idle)
        let pending = c.hudHide

        c.applyState(.recording)

        XCTAssertEqual(pending?.isCancelled, true)
        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
    }

    // MARK: - Pill waits out a tap

    func testARecordingStartDoesNotShowThePillAtOnce() {
        let c = make(holdThreshold: 60)

        c.applyState(.recording)

        XCTAssertEqual(hud.phase, .hidden)
        c.applyState(.idle)
    }

    func testATapShorterThanTheThresholdNeverShowsThePill() async {
        let c = make(holdThreshold: 0.05)
        c.applyState(.recording)
        let pending = c.hudShow

        c.applyState(.idle)
        await pending?.value

        XCTAssertEqual(pending?.isCancelled, true)
        XCTAssertEqual(hud.phase, .hidden)
    }

    func testAHoldThatOutlastsTheThresholdShowsListening() async {
        let c = make(holdThreshold: 0.05)

        c.applyState(.recording)
        XCTAssertEqual(hud.phase, .hidden)

        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
    }

    func testSetHoldThresholdChangesTheDelayBeforeThePillShows() async {
        let c = make(holdThreshold: 60)
        c.setHoldThreshold(0.05)

        c.applyState(.recording)

        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
    }

    func testSetHoldThresholdReachesThePipeline() {
        let c = make()
        c.setHoldThreshold(1.0)

        c.handleKeyDown()
        pipelineClock.t += 0.5
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, [], "half a second is a tap under a one second threshold")

        c.setHoldThreshold(0.3)
        c.handleKeyDown()
        pipelineClock.t += 0.5
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, ["job"])
    }

    func testProcessingAfterAHoldThatEndedBeforeThePillShowedStillShowsTranscribing() async {
        let c = make(holdThreshold: 0.05)
        c.applyState(.recording)
        let pending = c.hudShow

        c.applyState(.processing)
        await pending?.value

        XCTAssertEqual(pending?.isCancelled, true)
        XCTAssertEqual(hud.phase, .processing)
    }

    func testTurningThePillOffDuringTheDelayNeverShowsIt() async {
        let c = make(holdThreshold: 0.05)
        c.applyState(.recording)
        let pending = c.hudShow

        c.setHudEnabled(false)
        await pending?.value

        XCTAssertEqual(pending?.isCancelled, true)
        XCTAssertEqual(hud.phase, .hidden)
    }

    func testTheDelayStartsAtThePipelineConfigsThreshold() async {
        let c = make(config: PipelineConfig(holdThreshold: 60), holdThreshold: nil)

        c.applyState(.recording)
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(hud.phase, .hidden, "a 0.3 s fallback would have shown the pill by now")
        c.applyState(.idle)
    }

    func testANegativeThresholdShowsThePillWithoutTrapping() async {
        let c = make(holdThreshold: -1)

        c.applyState(.recording)

        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
    }

    func testANonFiniteThresholdShowsThePillWithoutTrapping() async {
        let c = make(holdThreshold: .nan)

        c.applyState(.recording)

        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
    }

    func testAVerdictDuringTheDelayGivesWayToListening() async {
        let c = make()
        c.applyState(.processing)
        c.applyState(.recording)
        c.playPasteCue()
        XCTAssertEqual(hud.phase, .result("Pasted"))

        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
    }

    func testABriefTapWhileTheVerdictIsUpLetsItHideOnSchedule() async {
        let c = make(hudResultSeconds: 0.05, holdThreshold: 60)
        c.applyState(.processing)
        c.playPasteCue()
        c.applyState(.idle)
        c.applyState(.recording)
        c.applyState(.idle)
        XCTAssertEqual(hud.phase, .result("Pasted"))

        let hidden = await eventually { [unowned self] in hud.phase == .hidden }
        XCTAssertTrue(hidden)
    }

    func testAVerdictWithThePillHiddenShowsNothing() {
        let c = make()

        c.playPasteCue()
        c.showHint("Pasted raw — cleanup timed out")

        XCTAssertEqual(hud.phase, .hidden)
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

        monitorDown(false)
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

        monitorDown(false)
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

    // MARK: - Latch mode

    /// A press and release, `hold` seconds apart, then `gap` seconds of quiet.
    private func tap(_ c: DictationCoordinator, hold: Double = 0.1, gap: Double = 0.2) {
        c.handleKeyDown()
        pipelineClock.t += hold
        c.handleKeyUp()
        pipelineClock.t += gap
    }

    /// A double tap in `holdOrLatch`: the first tap's hold is discarded by the pipeline, the second down latches.
    private func latch(_ c: DictationCoordinator) {
        tap(c)
        c.handleKeyDown()
        pipelineClock.t += 0.1
        c.handleKeyUp()
    }

    func testHoldModeUnchanged() {
        // A real tap threshold: at the default 0.05 s the 0.1 s presses below are not taps, and the second-tap half
        // could never latch in any mode.
        let c = make(holdThreshold: 0.3)
        var hookCalls = 0
        c.onKeyDown = { hookCalls += 1 }

        c.handleKeyDown()
        XCTAssertEqual(hookCalls, 1)
        XCTAssertTrue(recorder.armed)
        let watchdog = c.holdWatchdog
        XCTAssertNotNil(watchdog)
        pipelineClock.t += 1.0
        c.handleKeyUp()

        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(watchdog?.isCancelled, true)
        XCTAssertEqual(jobs.value, ["job"])

        // Two quick taps never latch in hold mode: the second release stops the recording.
        tap(c, hold: 0.1, gap: 0.1)
        c.handleKeyDown()
        XCTAssertTrue(recorder.armed)
        pipelineClock.t += 0.1
        c.handleKeyUp()
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(jobs.value, ["job"], "both taps were discarded as taps")
    }

    /// Everything a hold touches, so a chord hold can be compared with a plain one as a whole.
    private struct HoldTrace: Equatable {
        var states: [PipelineState] = []
        var hookCalls = 0
        var armedWhileHeld = false
        var watchdogSet = false
        var armedAfterRelease = true
        var watchdogCancelledByRelease = false
        var jobs: [String] = []
        var sounds: [String] = []
    }

    /// Starts from fresh fixtures, so two traces in one test never see each other's recorder, jobs or clock.
    private func traceHold(_ press: (DictationCoordinator) -> Void) async -> HoldTrace {
        recorder = FakeRecorder()
        jobs = Box<String>()
        sounds = Box<String>()
        pipelineClock = FakeClock()
        monitors = []
        let c = make(holdThreshold: 0.3)
        let seen = Box<PipelineState>()
        let subscription = c.$state.sink { seen.append($0) }
        var hookCalls = 0
        c.onKeyDown = { hookCalls += 1 }

        press(c)
        let recording = await eventually { c.state == .recording }
        XCTAssertTrue(recording)
        var trace = HoldTrace()
        trace.hookCalls = hookCalls
        trace.armedWhileHeld = recorder.armed
        let watchdog = c.holdWatchdog
        trace.watchdogSet = watchdog != nil
        pipelineClock.t += 1.0
        c.handleKeyUp()
        trace.armedAfterRelease = recorder.armed
        trace.watchdogCancelledByRelease = watchdog?.isCancelled == true
        trace.jobs = jobs.value
        trace.sounds = sounds.value
        trace.states = seen.value
        subscription.cancel()
        return trace
    }

    func testAChordDownIsAPlainHoldUntilEditsExist() async {
        let plain = await traceHold { $0.handleKeyDown() }
        let chord = await traceHold { $0.handleKeyDown(chord: true) }

        // The plain hold `testHoldModeUnchanged` pins: hook once, armed with a watchdog, released into one job.
        XCTAssertEqual(
            plain,
            HoldTrace(
                states: [.idle, .recording], hookCalls: 1, armedWhileHeld: true, watchdogSet: true,
                armedAfterRelease: false, watchdogCancelledByRelease: true, jobs: ["job"], sounds: ["Pop"]))
        XCTAssertEqual(chord, plain)
    }

    func testTheMonitorsChordCallbackStartsAPlainHold() {
        let c = make()
        var hookCalls = 0
        c.onKeyDown = { hookCalls += 1 }

        monitorDown(true)
        XCTAssertEqual(hookCalls, 1)
        XCTAssertTrue(recorder.armed)
        XCTAssertNotNil(c.holdWatchdog)

        monitorUp()
        XCTAssertFalse(recorder.armed)
    }

    func testDoubleTapLatchesAndTapStops() {
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch)

        tap(c, hold: 0.1, gap: 0.2)
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(jobs.value, [], "the first tap's short hold is discarded by the pipeline as today")

        c.handleKeyDown()
        XCTAssertTrue(recorder.armed)
        pipelineClock.t += 0.1
        c.handleKeyUp()
        XCTAssertTrue(recorder.armed, "the latching tap's own release does not stop the recording")
        XCTAssertEqual(jobs.value, [])

        pipelineClock.t += 30
        let watchdog = c.holdWatchdog
        c.handleKeyDown()
        XCTAssertFalse(recorder.armed, "the next tap stops it")
        XCTAssertEqual(jobs.value, ["job"], "one completed job after the stopping tap")
        XCTAssertEqual(watchdog?.isCancelled, true)

        pipelineClock.t += 0.1
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, ["job"], "the stopping tap's release means nothing")

        // The stopping tap never seeds a new double tap.
        pipelineClock.t += 0.1
        c.handleKeyDown()
        XCTAssertTrue(recorder.armed, "a plain start, not a second latch")
        pipelineClock.t += 1.0
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, ["job", "job"])
    }

    func testLatchedWatchdogUsesTheLongerCapAndItsNotice() async {
        let c = make(
            config: PipelineConfig(maxHold: 60), holdThreshold: 0.3, hotkeyMode: .holdOrLatch, latchMaxSeconds: 0.05)
        latch(c)
        pipelineClock.t += 10  // long enough to be a dictation when the watchdog stops it

        let notified = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(notified)
        XCTAssertEqual(notifier.delivered.first?.body, "Stopped after 0 min — tap to start again")
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(jobs.value, ["job"])
        XCTAssertEqual(monitor.forgetCalls, 1)

        c.handleKeyDown()
        XCTAssertTrue(recorder.armed, "the watchdog reset the interpreter, so this is a plain start and not a stopping tap")
        c.handleKeyUp()
    }

    func testHoldWatchdogNoticeUnchanged() async {
        let c = make(
            config: PipelineConfig(maxHold: 0.05), holdThreshold: 0.3, hotkeyMode: .holdOrLatch, latchMaxSeconds: 600)

        c.handleKeyDown()

        let notified = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(notified)
        XCTAssertEqual(notifier.delivered.first?.body, "Stopped after 0 min — release the key")
        XCTAssertFalse(recorder.armed)

        c.handleKeyUp()  // the late release
        c.handleKeyDown()
        XCTAssertTrue(recorder.armed, "a plain start after the forced stop")
        c.handleKeyUp()
    }

    func testToggleLatchedStartsAndStops() {
        let c = make(hotkeyMode: .holdOrLatch)
        var hookCalls = 0
        c.onKeyDown = { hookCalls += 1 }

        c.toggleLatched()
        XCTAssertTrue(recorder.armed)
        XCTAssertEqual(hookCalls, 1, "the key-down hook runs for a toggle start too")
        XCTAssertNotNil(c.holdWatchdog)
        let watchdog = c.holdWatchdog

        pipelineClock.t += 5
        c.toggleLatched()

        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(jobs.value, ["job"])
        XCTAssertEqual(watchdog?.isCancelled, true)

        // The next key press is a plain start: toggling off leaves no latch behind.
        c.handleKeyDown()
        XCTAssertTrue(recorder.armed)
        pipelineClock.t += 1
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, ["job", "job"])
    }

    func testATapStopsARecordingThatToggleStarted() {
        let c = make()
        c.toggleLatched()
        pipelineClock.t += 5

        c.handleKeyDown()
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(jobs.value, ["job"])
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, ["job"])
    }

    func testToggleLatchedEndsAHoldInProgress() {
        let c = make()
        c.handleKeyDown()
        pipelineClock.t += 1

        c.toggleLatched()
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(jobs.value, ["job"])

        c.handleKeyUp()  // the physical release arrives afterwards
        XCTAssertEqual(jobs.value, ["job"])
    }

    func testToggleLatchedUsesTheLatchCapAndNotice() async {
        let c = make(config: PipelineConfig(maxHold: 60), latchMaxSeconds: 0.05)
        c.toggleLatched()

        let notified = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(notified)
        XCTAssertEqual(notifier.delivered.first?.body, "Stopped after 0 min — tap to start again")
        XCTAssertFalse(recorder.armed)
    }

    func testAFailedLatchedStartLeavesNoPhantomLatch() {
        recorder = FakeRecorder(armError: TestError(message: "no mic"))
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch)
        tap(c)
        c.handleKeyDown()  // the latching tap, but the recorder cannot arm
        pipelineClock.t += 0.1
        c.handleKeyUp()
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(c.holdWatchdog?.isCancelled, true, "nothing is recording, so no cap is left running")

        recorder.armError = nil
        pipelineClock.t += 1
        c.handleKeyDown()

        XCTAssertTrue(recorder.armed, "the next tap starts a recording; it is not eaten as the tap that stops a latch")
        c.handleKeyUp()
    }

    func testAFailedToggleStartLeavesNoPhantomLatch() {
        recorder = FakeRecorder(armError: TestError(message: "no mic"))
        let c = make()
        c.toggleLatched()
        XCTAssertFalse(recorder.armed)

        recorder.armError = nil
        c.handleKeyDown()

        XCTAssertTrue(recorder.armed)
        c.handleKeyUp()
    }

    func testModeChangeEndsAHold() {
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch)
        latch(c)
        XCTAssertTrue(recorder.armed)
        let watchdog = c.holdWatchdog
        pipelineClock.t += 10

        c.setHotkeyMode(.hold)

        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(watchdog?.isCancelled, true)
        XCTAssertEqual(jobs.value, ["job"], "the dictation so far is kept, not thrown away")

        // The new mode applies at once, and the dropped latch does not eat the next press.
        tap(c, hold: 0.1, gap: 0.1)
        c.handleKeyDown()
        XCTAssertTrue(recorder.armed)
        pipelineClock.t += 0.1
        c.handleKeyUp()
        XCTAssertFalse(recorder.armed, "hold mode: the second tap is a plain hold, not a latch")
    }

    func testSwitchingToLatchModeMakesTheNextDoubleTapLatch() {
        let c = make(holdThreshold: 0.3)
        c.setHotkeyMode(.holdOrLatch)

        latch(c)

        XCTAssertTrue(recorder.armed)
        pipelineClock.t += 5
        c.handleKeyDown()
        XCTAssertFalse(recorder.armed)
    }

    func testChangingModeWithNothingRecordingStartsNothing() {
        let c = make(hotkeyMode: .holdOrLatch)

        c.setHotkeyMode(.hold)

        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(jobs.value, [])
    }

    func testSleepResetsALatch() async {
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch)
        c.start()
        latch(c)
        XCTAssertTrue(recorder.armed)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        let stopped = await eventually { !recorder.armed }
        XCTAssertTrue(stopped)
        XCTAssertEqual(jobs.value, [], "a hold cut off by sleep must not become a dictation")

        c.handleKeyDown()
        XCTAssertTrue(recorder.armed, "after waking, a tap starts; it does not stop the latch that sleep already ended")
        c.handleKeyUp()
    }

    func testSetHotkeyResetsALatch() {
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch)
        c.start()
        latch(c)
        XCTAssertTrue(recorder.armed)

        c.setHotkey(.f13)

        XCTAssertFalse(recorder.armed)
        c.handleKeyDown()
        XCTAssertTrue(recorder.armed, "the new key's first tap starts a recording")
        c.handleKeyUp()
    }

    func testChangingTheMicrophoneEndsALatchAndKeepsItsWords() {
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch)
        latch(c)
        let watchdog = c.holdWatchdog
        pipelineClock.t += 10

        c.selectMicrophone(uid: "usb-mic")

        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(watchdog?.isCancelled, true)
        XCTAssertEqual(jobs.value, ["job"], "what was said before the switch is kept")
        XCTAssertEqual(recorder.preferredInputs.last, "usb-mic")
        c.handleKeyDown()
        XCTAssertTrue(recorder.armed, "the next tap starts a recording; it does not stop a latch that already ended")
        c.handleKeyUp()
    }

    func testLatchedStartShowsThePillAtOnce() {
        let c = make(holdThreshold: 60, hotkeyMode: .holdOrLatch)
        tap(c)
        XCTAssertEqual(hud.phase, .hidden)

        c.handleKeyDown()

        XCTAssertEqual(hud.phase, .listening, "the double tap has already outlasted the tap filter")
        c.handleKeyUp()
    }

    func testAToggleStartShowsThePillAtOnce() {
        let c = make(holdThreshold: 60)

        c.toggleLatched()

        XCTAssertEqual(hud.phase, .listening)
    }

    func testALatchedStartWithThePillOffShowsNothing() {
        hudEnabled = false
        let c = make(holdThreshold: 60, hotkeyMode: .holdOrLatch)
        tap(c)

        c.handleKeyDown()

        XCTAssertEqual(hud.phase, .hidden)
        c.handleKeyUp()
    }

    func testALatchedStartCancelsAPendingHide() {
        let c = make(hudResultSeconds: 0.05, holdThreshold: 60, hotkeyMode: .holdOrLatch)
        c.applyState(.processing)
        c.playPasteCue()
        c.applyState(.idle)
        let pending = c.hudHide
        XCTAssertNotNil(pending)
        tap(c)
        XCTAssertEqual(pending?.isCancelled, false, "nothing has cancelled it yet")

        c.handleKeyDown()

        XCTAssertEqual(pending?.isCancelled, true, "the verdict's hide must not blank a live recording")
        XCTAssertEqual(hud.phase, .listening)
        c.handleKeyUp()
    }

    func testPlainHoldStillWaitsForTheThreshold() async {
        let c = make(holdThreshold: 60, hotkeyMode: .holdOrLatch)

        c.handleKeyDown()
        let recording = await eventually { c.state == .recording }
        XCTAssertTrue(recording)

        XCTAssertEqual(hud.phase, .hidden, "a plain hold shows the pill only once it outlasts the threshold")
        c.handleKeyUp()
        c.applyState(.idle)  // cancels the pending show
    }

    func testSetHoldThresholdReachesTheTapFilter() {
        let c = make(hotkeyMode: .holdOrLatch)

        // At 1.0 s a 0.6 s press is a tap, so the quick second press latches.
        c.setHoldThreshold(1.0)
        tap(c, hold: 0.6, gap: 0.2)
        c.handleKeyDown()
        pipelineClock.t += 0.1
        c.handleKeyUp()
        XCTAssertTrue(recorder.armed, "latched")
        pipelineClock.t += 5
        c.handleKeyDown()
        XCTAssertFalse(recorder.armed)
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, ["job"])

        // At 0.3 s the same press is a real hold, so the second press is a plain one.
        c.setHoldThreshold(0.3)
        pipelineClock.t += 1
        tap(c, hold: 0.6, gap: 0.2)
        XCTAssertEqual(jobs.value, ["job", "job"])
        c.handleKeyDown()
        XCTAssertTrue(recorder.armed)
        pipelineClock.t += 0.1
        c.handleKeyUp()
        XCTAssertFalse(recorder.armed, "not latched")
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

    func testSetVoiceCommandsEnabledReachesThePipeline() {
        let c = make()
        XCTAssertTrue(c.pipeline.voiceCommandsEnabled)

        c.setVoiceCommandsEnabled(false)

        XCTAssertFalse(c.pipeline.voiceCommandsEnabled)
    }
}

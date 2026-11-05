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
    private var editSinks: EditSinks!
    /// What the edit pipeline enqueued: queued and never run, like `jobs`, so only whether a hold produced one matters.
    private var editJobs: Box<String>!
    private var editStats: Box<EditStat>!
    private var editEnabled = true
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
        editSinks = nil
        editJobs = Box<String>()
        editStats = Box<EditStat>()
        editEnabled = true
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
        latchMaxSeconds: Double = 240,
        withEdits: Bool = false
    ) -> DictationCoordinator {
        let recorder = self.recorder!
        let clock = pipelineClock!
        let jobs = self.jobs!
        let editJobs = self.editJobs!
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
            makeEditPipeline: withEdits
                ? { [unowned self] sinks in
                    self.editSinks = sinks
                    return EditPipeline(
                        recorder: recorder, stt: FakeStt(text: "make it shorter"), backend: { FakeEditBackend() },
                        modelIsGemma4: { false }, selection: FakeSelectionReader(nil), paster: FakeSelectionReplacer(),
                        config: config, clock: { clock.t },
                        sinks: EditSinks(
                            onState: sinks.onState, onNotice: sinks.onNotice, onVerdict: sinks.onVerdict,
                            onProblem: sinks.onProblem, onStat: sinks.onStat, runner: { _ in editJobs.append("job") }))
                } : nil,
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
            editEnabled: { [unowned self] in editEnabled },
            onEditStat: { [unowned self] in editStats.append($0) },
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

    // MARK: - Edit by voice

    func testAPlainHoldRunsTheSameWithEditsWiredOnOrOffAsWithNoEditsAtAll() async {
        let baseline = await traceHold { $0.handleKeyDown() }
        editEnabled = true
        let editsOn = await traceHold(withEdits: true) { $0.handleKeyDown() }
        editEnabled = false
        let editsOff = await traceHold(withEdits: true) { $0.handleKeyDown() }

        XCTAssertEqual(
            baseline,
            HoldTrace(
                states: [.idle, .recording], hookCalls: 1, armedWhileHeld: true, watchdogSet: true,
                armedAfterRelease: false, watchdogCancelledByRelease: true, jobs: ["job"], sounds: ["Pop"]))
        XCTAssertEqual(editsOn, baseline)
        XCTAssertEqual(editsOff, baseline)
        XCTAssertTrue(editJobs.value.isEmpty, "a plain hold never reaches the edit pipeline")
    }

    func testAChordWithEditsOffOrMissingIsTheSamePlainHold() async {
        editEnabled = false
        let off = await traceHold(withEdits: true) { $0.handleKeyDown(chord: true) }
        editEnabled = true
        let missing = await traceHold(withEdits: false) { $0.handleKeyDown(chord: true) }
        let plain = await traceHold { $0.handleKeyDown() }

        XCTAssertEqual(off, plain)
        XCTAssertEqual(missing, plain)
    }

    func testEditDisabledMakesAChordAPlainHold() {
        editEnabled = false
        let c = make(withEdits: true)
        var editHooks = 0
        c.onEditKeyDown = { editHooks += 1 }

        c.handleKeyDown(chord: true)

        XCTAssertTrue(c.pipeline.isArmed)
        XCTAssertFalse(c.editPipeline?.isArmed == true)
        XCTAssertNotEqual(hud.phase, .editing)
        XCTAssertEqual(editHooks, 0)
        pipelineClock.t += 1
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, ["job"])
        XCTAssertTrue(editJobs.value.isEmpty)
    }

    func testNoEditPipelineMakesAChordAPlainHold() {
        let c = make(withEdits: false)

        c.handleKeyDown(chord: true)

        XCTAssertNil(c.editPipeline)
        XCTAssertTrue(c.pipeline.isArmed)
        pipelineClock.t += 1
        c.handleKeyUp()
        XCTAssertEqual(jobs.value, ["job"])
    }

    func testAChordStartsAnEditAndShowsEditingAtOnce() async {
        let c = make(withEdits: true)
        var hookCalls = 0
        var editHooks = 0
        c.onKeyDown = { hookCalls += 1 }
        c.onEditKeyDown = { editHooks += 1 }

        c.handleKeyDown(chord: true)

        XCTAssertEqual(hud.phase, .editing, "no wait for the tap threshold: the chord is deliberate")
        XCTAssertTrue(recorder.armed)
        XCTAssertTrue(c.editPipeline?.isArmed == true)
        XCTAssertFalse(c.pipeline.isArmed, "the two pipelines are never both armed")
        XCTAssertNotNil(c.holdWatchdog)
        XCTAssertEqual(hookCalls, 1)
        XCTAssertEqual(editHooks, 1)
        let recording = await eventually { c.state == .recording }
        XCTAssertTrue(recording)
        XCTAssertEqual(sounds.value, ["Pop"], "the recording cue is kept")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(hud.phase, .editing, "the pipeline's .recording must not schedule the delayed Listening")
        c.handleKeyUp()
    }

    func testTheMonitorsChordCallbackStartsAnEdit() {
        let c = make(withEdits: true)

        monitorDown(true)
        XCTAssertTrue(c.editPipeline?.isArmed == true)
        XCTAssertEqual(hud.phase, .editing)

        monitorUp()
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(editJobs.value, [])  // 0 s hold: a tap, discarded
    }

    func testAChordWithThePillOffShowsNothingButStillEdits() {
        hudEnabled = false
        let c = make(withEdits: true)

        c.handleKeyDown(chord: true)

        XCTAssertEqual(hud.phase, .hidden)
        XCTAssertTrue(c.editPipeline?.isArmed == true)
        c.handleKeyUp()
    }

    func testAChordKeyDownClearsTheHint() {
        let c = make(withEdits: true)
        c.showHint("Pasted raw — cleanup timed out")
        XCTAssertNotNil(c.hint)

        c.handleKeyDown(chord: true)

        XCTAssertNil(c.hint)
        c.handleKeyUp()
    }

    func testTheChordReleaseEndsTheEditNotADictation() {
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch, withEdits: true)

        c.handleKeyDown(chord: true)
        let watchdog = c.holdWatchdog
        pipelineClock.t += 1.0
        c.handleKeyUp()

        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(watchdog?.isCancelled, true)
        XCTAssertEqual(editJobs.value, ["job"])
        XCTAssertTrue(jobs.value.isEmpty, "the release is the edit's, not a dictation's")
    }

    func testAChordTapNeverFeedsTheDoubleTapInterpreter() {
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch, withEdits: true)

        c.handleKeyDown(chord: true)
        pipelineClock.t += 0.1
        c.handleKeyUp()
        pipelineClock.t += 0.1
        c.handleKeyDown()   // 0.2 s after the chord tap, well inside the 0.4 s double-tap window
        XCTAssertTrue(recorder.armed)
        pipelineClock.t += 0.1
        c.handleKeyUp()

        XCTAssertFalse(recorder.armed, "a plain tap after a chord tap is a tap, not the second half of a latch")
        XCTAssertTrue(jobs.value.isEmpty, "both were taps and both were discarded")
    }

    func testTheWatchdogEndsAnEditWithForceStop() async {
        let c = make(config: PipelineConfig(maxHold: 0.05), withEdits: true)

        c.handleKeyDown(chord: true)
        pipelineClock.t += 130  // the fake clock's view of a hold that outlasted the watchdog

        let forgot = await eventually { monitor.forgetCalls == 1 }
        XCTAssertTrue(forgot)
        XCTAssertFalse(recorder.armed)
        let notified = await eventually { !notifier.delivered.isEmpty }
        XCTAssertTrue(notified)
        XCTAssertEqual(notifier.delivered.first?.body, "Stopped after 0 min — release the key")
        XCTAssertEqual(editJobs.value, ["job"])
        XCTAssertTrue(jobs.value.isEmpty)
        // The release will never arrive, so the next chord must not be taken for part of the dead edit.
        c.handleKeyDown(chord: true)
        XCTAssertTrue(c.editPipeline?.isArmed == true)
        c.handleKeyUp()
    }

    func testKeyUpCancelsTheEditWatchdog() async {
        let c = make(config: PipelineConfig(maxHold: 0.05), withEdits: true)
        c.handleKeyDown(chord: true)
        let watchdog = c.holdWatchdog

        c.handleKeyUp()
        await watchdog?.value

        XCTAssertEqual(monitor.forgetCalls, 0)
        XCTAssertTrue(notifier.delivered.isEmpty)
    }

    func testAVerdictShowsOnThePillThenHides() async {
        let c = make(hudResultSeconds: 0.3, withEdits: true)
        c.handleKeyDown(chord: true)
        pipelineClock.t += 1
        c.handleKeyUp()

        editSinks.onState(.processing)
        editSinks.onVerdict("Shorter")
        editSinks.onState(.idle)

        let shown = await eventually { [unowned self] in hud.phase == .result("Shorter") }
        XCTAssertTrue(shown)
        XCTAssertEqual(c.hint, "Shorter")
        let hidden = await eventually { [unowned self] in hud.phase == .hidden }
        XCTAssertTrue(hidden)
    }

    func testARejectionVerdictShowsOnThePillLikeAHint() async {
        let c = make(hudResultSeconds: 0.3, withEdits: true)
        c.handleKeyDown(chord: true)
        pipelineClock.t += 1
        c.handleKeyUp()
        let reason = EditGates.pillReason(.length, modelIsGemma4: false)

        editSinks.onState(.processing)
        editSinks.onVerdict(reason)
        editSinks.onState(.idle)

        let shown = await eventually { [unowned self] in hud.phase == .result(reason) }
        XCTAssertTrue(shown)
        withExtendedLifetime(c) {}
    }

    func testAnEditFailureShowsAsAProblemOnThePillThenHides() async {
        let c = make(hudResultSeconds: 0.3, withEdits: true)
        c.handleKeyDown(chord: true)
        pipelineClock.t += 1
        c.handleKeyUp()

        editSinks.onState(.processing)
        editSinks.onProblem("Edit failed — transcription")
        editSinks.onState(.idle)

        let shown = await eventually { [unowned self] in hud.phase == .problem("Edit failed — transcription") }
        XCTAssertTrue(shown, "a failure is a ⚠, where a rejection is a ◦ result")
        XCTAssertEqual(c.hint, "Edit failed — transcription", "the menu's status row says it too")
        let hidden = await eventually { [unowned self] in hud.phase == .hidden }
        XCTAssertTrue(hidden)
    }

    func testAProblemFromAnEarlierEditJobNeverCoversALiveHold() async {
        let c = make(withEdits: true)
        c.handleKeyDown()
        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)

        editSinks.onProblem("Edit failed — check log")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(hud.phase, .listening, "the level bars of the live hold stay up")
        XCTAssertEqual(c.hint, "Edit failed — check log")
        c.handleKeyUp()
    }

    func testAProblemBeforeAHoldsPillAppearsDoesNotScheduleAHideThatTakesItDown() async {
        let c = make(hudResultSeconds: 0.1, holdThreshold: 0.05, withEdits: true)
        c.handleKeyDown()

        editSinks.onProblem("Edit failed — check log")   // the pill is still hidden: Listening waits out the tap threshold
        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(hud.phase, .listening, "a hide scheduled for the problem must not outlive it into the hold")
        c.handleKeyUp()
    }

    func testARecorderThatWillNotStartShowsTheProblemOnThePill() async {
        recorder.armError = TestError(message: "no input device")
        let c = make(hudResultSeconds: 0.3, withEdits: true)

        c.handleKeyDown(chord: true)

        let notice = UserFacingError.recordingNotice(error: "")
        let shown = await eventually { [unowned self] in hud.phase == .problem(notice) }
        XCTAssertTrue(shown, "no job pill to replace: the problem appears on its own")
        let hidden = await eventually { [unowned self] in hud.phase == .hidden }
        XCTAssertTrue(hidden)
        let delivered = await eventually { [unowned self] in notifier.delivered.count == 1 }
        XCTAssertTrue(delivered, "the banner is kept")
        XCTAssertEqual(notifier.delivered.first?.body, notice)
    }

    func testAnEditsNoticeIsDeliveredAndRecorded() async {
        let c = make(withEdits: true)

        editSinks.onNotice("Focus changed — text copied, press ⌘V")

        let delivered = await eventually { [unowned self] in notifier.delivered.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(notifier.delivered.first?.body, "Focus changed — text copied, press ⌘V")
        XCTAssertEqual(c.lastNotice?.text, "Focus changed — text copied, press ⌘V")
    }

    func testAnEditsStatReachesTheStatsRecorder() {
        _ = make(withEdits: true)
        let stat = EditStat(verb: .formal, sttMs: 200, editMs: 800, accepted: true, rejection: nil)

        editSinks.onStat(stat)

        XCTAssertEqual(editStats.value, [stat])
    }

    func testSleepCancelsAnEdit() async {
        let c = make(withEdits: true)
        c.start()
        c.handleKeyDown(chord: true)
        let watchdog = c.holdWatchdog
        XCTAssertTrue(recorder.armed)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        let forgot = await eventually { monitor.forgetCalls >= 1 }
        XCTAssertTrue(forgot)
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(watchdog?.isCancelled, true)
        XCTAssertTrue(editJobs.value.isEmpty, "a hold that sleep interrupted is not an edit")
        c.handleKeyDown(chord: true)
        XCTAssertTrue(c.editPipeline?.isArmed == true, "the first chord on wake starts an edit")
        c.handleKeyUp()
    }

    func testADictationDownDuringAnEditIsIgnored() {
        let c = make(withEdits: true)
        c.handleKeyDown(chord: true)

        c.handleKeyDown()
        c.handleKeyDown(chord: true)

        XCTAssertFalse(c.pipeline.isArmed, "no second recording on the one microphone")
        XCTAssertTrue(c.editPipeline?.isArmed == true)
        pipelineClock.t += 1
        c.handleKeyUp()
        XCTAssertEqual(editJobs.value, ["job"], "one hold, one edit")
        XCTAssertTrue(jobs.value.isEmpty)
    }

    func testToggleLatchedIsIgnoredDuringAnEdit() {
        let c = make(withEdits: true)
        c.handleKeyDown(chord: true)

        c.toggleLatched()

        XCTAssertFalse(c.pipeline.isArmed)
        XCTAssertTrue(c.editPipeline?.isArmed == true)
        c.handleKeyUp()
    }

    func testAChordWhileADictationIsLatchedStopsItAndStartsNoEdit() {
        let c = make(holdThreshold: 0.3, hotkeyMode: .holdOrLatch, withEdits: true)
        latch(c)
        XCTAssertTrue(c.pipeline.isArmed)
        pipelineClock.t += 5

        c.handleKeyDown(chord: true)

        XCTAssertFalse(c.pipeline.isArmed, "the chord is the tap that ends the latch")
        XCTAssertFalse(c.editPipeline?.isArmed == true)
        XCTAssertTrue(editJobs.value.isEmpty)
        XCTAssertEqual(jobs.value, ["job"], "what was said is kept")
        c.handleKeyUp()
    }

    func testARecorderThatWillNotStartLeavesNoEditBehind() {
        recorder.armError = TestError(message: "no input device")
        let c = make(withEdits: true)

        c.handleKeyDown(chord: true)

        XCTAssertNotEqual(hud.phase, .editing)
        XCTAssertFalse(c.editPipeline?.isArmed == true)
        XCTAssertEqual(c.holdWatchdog?.isCancelled, true)
        recorder.armError = nil
        c.handleKeyUp()
        c.handleKeyDown()
        XCTAssertTrue(c.pipeline.isArmed, "the next plain hold is not swallowed as part of a dead edit")
        c.handleKeyUp()
    }

    func testADictationJobFinishingDuringAnEditLeavesTheEditingPill() {
        let c = make(withEdits: true)
        c.handleKeyDown(chord: true)

        c.applyState(.processing)   // the dictation ahead of the edit starts its last step
        c.applyState(.idle)         // and ends

        XCTAssertEqual(hud.phase, .editing, "that idle is not this hold's")
        pipelineClock.t += 1
        c.handleKeyUp()
        c.applyState(.processing, from: .edit)   // the edit's own job
        XCTAssertEqual(hud.phase, .processing)
        c.applyState(.idle, from: .edit)
        XCTAssertEqual(hud.phase, .hidden)
    }

    // MARK: - One pipeline holds the microphone: the other's jobs finish unseen

    func testAnEditJobStartingDuringADictationHoldKeepsTheMenuStateAndTheListeningPill() async {
        let c = make(holdThreshold: 0.3, withEdits: true)
        c.handleKeyDown()
        // Inside the tap threshold: an edit released just before this hold starts its job.
        editSinks.onState(.processing)

        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening, "the delayed Listening pill must not be cancelled by the other pipeline's state")
        XCTAssertEqual(c.state, .recording, "the microphone is recording, so the menu bar says so")
        c.handleKeyUp()
    }

    func testAnEditJobEndingDuringADictationHoldLeavesTheListeningPillUpAndThenTheDictationsStatesApply() async {
        let c = make(holdThreshold: 0.05, withEdits: true)
        c.handleKeyDown()
        let listening = await eventually { [unowned self] in hud.phase == .listening }
        XCTAssertTrue(listening)

        editSinks.onState(.processing)
        editSinks.onState(.idle)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(hud.phase, .listening, "an edit's idle must not hide the pill mid-hold")
        XCTAssertEqual(c.state, .recording)

        pipelineClock.t += 1
        c.handleKeyUp()
        sinks.onState(.processing)
        let transcribing = await eventually { [unowned self] in hud.phase == .processing }
        XCTAssertTrue(transcribing, "once the hold is over the dictation's own states apply")
        XCTAssertEqual(c.state, .processing)
        sinks.onState(.idle)
        let hidden = await eventually { [unowned self] in hud.phase == .hidden }
        XCTAssertTrue(hidden)
        XCTAssertEqual(c.state, .idle)
    }

    func testADictationJobsStatesDuringAnEditHoldLeaveTheMenuStateAndThePillAndThenTheEditsApply() async {
        let c = make(withEdits: true)
        c.handleKeyDown(chord: true)
        let recording = await eventually { c.state == .recording }
        XCTAssertTrue(recording)

        sinks.onState(.processing)
        sinks.onState(.idle)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(c.state, .recording, "a dictation job ending is not the edit hold's news")
        XCTAssertEqual(hud.phase, .editing)

        pipelineClock.t += 1
        c.handleKeyUp()
        editSinks.onState(.processing)
        let processing = await eventually { [unowned self] in hud.phase == .processing }
        XCTAssertTrue(processing, "once the hold is over the edit's own states apply")
        XCTAssertEqual(c.state, .processing)
        editSinks.onState(.idle)
        let hidden = await eventually { [unowned self] in hud.phase == .hidden }
        XCTAssertTrue(hidden)
        XCTAssertEqual(c.state, .idle)
    }

    func testTheLevelReachesThePillWhileEditing() {
        let c = make(withEdits: true)
        c.handleKeyDown(chord: true)

        c.reportLevel(rms: 0.1)

        XCTAssertEqual(hud.level, 0.8, accuracy: 0.01)
        c.handleKeyUp()
    }

    func testChangingTheMicrophoneEndsAnEditAndKeepsItsWords() {
        let c = make(withEdits: true)
        c.handleKeyDown(chord: true)
        pipelineClock.t += 10

        c.selectMicrophone(uid: "usb-mic")

        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(editJobs.value, ["job"])
        XCTAssertEqual(recorder.preferredInputs.last, "usb-mic")
        c.handleKeyDown(chord: true)
        XCTAssertTrue(c.editPipeline?.isArmed == true, "the next chord starts a fresh edit")
        c.handleKeyUp()
    }

    func testSetHotkeyEndsAnEditInProgress() {
        let c = make(withEdits: true)
        c.handleKeyDown(chord: true)
        let watchdog = c.holdWatchdog

        c.setHotkey(.rightCommand)

        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(watchdog?.isCancelled, true)
        XCTAssertTrue(editJobs.value.isEmpty, "the old key's release will never arrive")
        c.handleKeyDown(chord: true)
        XCTAssertTrue(c.editPipeline?.isArmed == true)
        c.handleKeyUp()
    }

    func testSetHoldThresholdReachesTheEditPipeline() {
        let c = make(withEdits: true)
        c.setHoldThreshold(2.0)

        c.handleKeyDown(chord: true)
        pipelineClock.t += 1.0
        c.handleKeyUp()

        XCTAssertTrue(editJobs.value.isEmpty, "a 1 s hold is a tap at a 2 s threshold")
    }

    /// Holds the dictation job open, so an edit queued behind it would overtake it if the worker were not shared.
    private struct SlowStt: SttEngine {
        let name = "parakeet"
        let events: Locked<[String]>

        func transcribe(_ pcm: [Float]) async throws -> String {
            events.mutate { $0.append("dictation begins") }
            try? await Task.sleep(nanoseconds: 60_000_000)
            events.mutate { $0.append("dictation ends") }
            return "so um hello there world"
        }
    }

    /// The edit job's first step after the release: reading the selection, which presses ⌘C in the real app.
    private struct CopyProbe: SelectionReader {
        let events: Locked<[String]>

        func read(target: pid_t?) async throws -> Selection? {
            events.mutate { $0.append("edit begins") }
            return nil
        }
    }

    func testBothPipelinesRunTheirJobsOnOneSerialWorker() async {
        let recorder = self.recorder!
        let clock = pipelineClock!
        let events = Locked<[String]>([])
        let c = DictationCoordinator(
            recorder: recorder, pipelineConfig: PipelineConfig(), hotkey: .rightOption,
            makePipeline: { sinks in
                // As the app builds it: the coordinator's worker, not a private one.
                DictationPipeline(
                    recorder: recorder, stt: SlowStt(events: events), cleaner: FakeCleaner(), paster: FakePaster(),
                    history: History(maxLen: 10), config: PipelineConfig(), clock: { clock.t }, runner: sinks.runner,
                    onState: sinks.onState, onNotice: sinks.onNotice, saveFailedAudio: sinks.saveFailedAudio)
            },
            makeEditPipeline: { sinks in
                EditPipeline(
                    recorder: recorder, stt: FakeStt(), backend: { nil }, modelIsGemma4: { false },
                    selection: CopyProbe(events: events), paster: FakeSelectionReplacer(), config: PipelineConfig(),
                    clock: { clock.t }, sinks: sinks)
            },
            makeHotkeyMonitor: { _, _, _ in FakeHotkeyMonitor() }, notifier: FakeNotifier(), playSound: { _ in },
            soundsEnabled: { false }, microphoneGranted: { true }, reportInputMonitoring: { _ in },
            repaste: { _ in }, editEnabled: { true }, now: { clock.t }, log: { _ in })

        // A real hold and release through each pipeline: the edit is released while the dictation is still working.
        c.handleKeyDown()
        clock.t += 1
        c.handleKeyUp()
        c.handleKeyDown(chord: true)
        clock.t += 1
        c.handleKeyUp()

        let ran = await eventually { events.value.count == 3 }
        XCTAssertTrue(ran)
        XCTAssertEqual(
            events.value, ["dictation begins", "dictation ends", "edit begins"],
            "an edit's ⌘C must never run while a dictation is still pasting")
        withExtendedLifetime(c) {}
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
    private func traceHold(withEdits: Bool = false, _ press: (DictationCoordinator) -> Void) async -> HoldTrace {
        recorder = FakeRecorder()
        jobs = Box<String>()
        editJobs = Box<String>()
        sounds = Box<String>()
        pipelineClock = FakeClock()
        monitors = []
        let c = make(holdThreshold: 0.3, withEdits: withEdits)
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

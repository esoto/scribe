import XCTest

/// Blocks the calling thread until the async work completes; a semaphore bridges the Task, no sleep polling.
private func runBlocking(_ work: @escaping () async -> Void) {
    let sema = DispatchSemaphore(value: 0)
    Task {
        await work()
        sema.signal()
    }
    sema.wait()
}

/// Queues work instead of running it, so a test can interleave keyDown/keyUp with processing.
private final class ManualRunner {
    private var queue: [() async -> Void] = []
    func run(_ work: @escaping () async -> Void) { queue.append(work) }
    /// Runs every queued job to completion, in order.
    func drain() {
        let jobs = queue
        queue.removeAll()
        for work in jobs { runBlocking(work) }
    }
}

final class PipelineTests: XCTestCase {
    private struct Harness {
        let pipeline: DictationPipeline
        let clock: FakeClock
        let states: Box<PipelineState>
        let notices: Box<String>
        let saved: Box<[Float]>
        let cleanedTexts: Box<String>
        let logs: Box<String>
        /// "pasted" and "hint: <text>" in the order the sinks fired.
        let cues: Box<String>
        let stats: Box<DictationStat>
    }

    private func makeSyncRunner() -> (@escaping () async -> Void) -> Void {
        return { work in runBlocking(work) }
    }

    private func make(
        recorder: RecorderLike = FakeRecorder(),
        stt: SttEngine = FakeStt(),
        cleaner: CleanupBackend? = FakeCleaner(),
        paster: Pasting = FakePaster(),
        history: History = History(maxLen: 10),
        config: PipelineConfig = PipelineConfig(),
        pairs: [ReplacementPair] = [],
        snippets: [Snippet] = [],
        runner: ((@escaping () async -> Void) -> Void)? = nil,
        frontmost: @escaping () -> pid_t? = { nil },
        enhancer: AudioEnhancer? = nil,
        enhanceEnabled: Bool = false,
        keyPresser: KeyPressing? = nil,
        voiceCommands: Bool = true,
        clock: FakeClock = FakeClock()
    ) -> Harness {
        let states = Box<PipelineState>()
        let notices = Box<String>()
        let saved = Box<[Float]>()
        let cleanedTexts = Box<String>()
        let logs = Box<String>()
        let cues = Box<String>()
        let stats = Box<DictationStat>()
        let pipeline = DictationPipeline(
            recorder: recorder,
            stt: stt,
            cleaner: cleaner,
            paster: paster,
            history: history,
            config: config,
            clock: { clock.t },
            runner: runner ?? makeSyncRunner(),
            frontmost: frontmost,
            onState: { states.append($0) },
            onNotice: { notices.append($0) },
            saveFailedAudio: { saved.append($0) },
            enhancer: enhancer,
            enhanceAudioEnabled: enhanceEnabled,
            keyPresser: keyPresser,
            voiceCommandsEnabled: voiceCommands,
            onLog: { logs.append($0) },
            onCleaned: { cleanedTexts.append($0) },
            replacementPairs: { pairs },
            snippets: { snippets },
            onHint: { cues.append("hint: \($0)") },
            onPasted: { cues.append("pasted") },
            onStats: { stats.append($0) }
        )
        return Harness(
            pipeline: pipeline, clock: clock, states: states, notices: notices, saved: saved,
            cleanedTexts: cleanedTexts, logs: logs, cues: cues, stats: stats)
    }

    private func dictate(_ h: Harness, hold: Double = 1.0) {
        h.pipeline.keyDown()
        h.clock.t += hold
        h.pipeline.keyUp()
    }

    /// Fails instead of hanging the suite if the pipeline never returns — the exact regression the deadline tests guard.
    private func dictateBounded(_ h: Harness, hold: Double = 1.0, limit: TimeInterval = 5.0) {
        h.pipeline.keyDown()
        h.clock.t += hold
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            h.pipeline.keyUp()
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + limit), .success, "pipeline did not return within \(limit) s")
    }

    func testHappyPathCleansAndPastes() {
        let paster = FakePaster()
        let hist = History(maxLen: 10)
        let h = make(paster: paster, history: hist)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["hello there world"])
        XCTAssertEqual(hist.items()[0].raw, "so um hello there world")
        XCTAssertTrue(hist.items()[0].cleaned)
        XCTAssertEqual(h.states.value.last, .idle)
        XCTAssertTrue(h.states.value.contains(.recording))
        XCTAssertTrue(h.states.value.contains(.processing))
    }

    func testSubThresholdTapDiscarded() {
        let stt = FakeStt()
        let h = make(stt: stt)
        dictate(h, hold: 0.1)
        XCTAssertEqual(stt.calls, 0)
    }

    func testSetHoldThresholdChangesWhatCountsAsATap() {
        let stt = FakeStt()
        let h = make(stt: stt)

        h.pipeline.setHoldThreshold(1.0)
        dictate(h, hold: 0.5)
        XCTAssertEqual(stt.calls, 0)
        XCTAssertEqual(h.states.value.last, .idle)

        h.pipeline.setHoldThreshold(0.3)
        dictate(h, hold: 0.5)
        XCTAssertEqual(stt.calls, 1)
    }

    func testEnergyGateDiscardsSilence() {
        let stt = FakeStt()
        let h = make(recorder: FakeRecorder(pcm: SILENT), stt: stt)
        dictate(h)
        XCTAssertEqual(stt.calls, 0)
    }

    func testShortUtteranceSkipsCleanup() {
        let cleaner = FakeCleaner()
        let paster = FakePaster()
        let h = make(stt: FakeStt(text: "just three words"), cleaner: cleaner, paster: paster)
        dictate(h)
        XCTAssertEqual(cleaner.calls, 0)
        XCTAssertEqual(paster.pasted, ["just three words"])
    }

    func testCleanupDisabledSkips() {
        let cleaner = FakeCleaner()
        let paster = FakePaster()
        let h = make(cleaner: cleaner, paster: paster)
        h.pipeline.cleanupEnabled = false
        dictate(h)
        XCTAssertEqual(cleaner.calls, 0)
        XCTAssertEqual(paster.pasted, ["so um hello there world"])
    }

    func testCleanupErrorFallsBackToRaw() {
        let paster = FakePaster()
        let h = make(cleaner: FakeCleaner(err: TestError(message: "boom")), paster: paster)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["so um hello there world"])
    }

    func testCleanupTimeoutFallsBackToRaw() {
        let paster = FakePaster()
        let config = PipelineConfig(cleanupTimeout: 0.01)
        let h = make(cleaner: FakeCleaner(delay: 0.2), paster: paster, config: config)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["so um hello there world"])
    }

    func testCleanupLengthGateFallsBack() {
        let paster = FakePaster()
        let h = make(cleaner: FakeCleaner(out: "x"), paster: paster)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["so um hello there world"])
    }

    func testCleanupEmptyFallsBack() {
        let paster = FakePaster()
        let h = make(cleaner: FakeCleaner(out: "   "), paster: paster)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["so um hello there world"])
    }

    func testNoCleanerPastesRaw() {
        let paster = FakePaster()
        let h = make(cleaner: nil, paster: paster)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["so um hello there world"])
    }

    // MARK: - Hints and the paste cue

    func testSilentCaptureHintsNoSpeechHeardWithoutANotice() {
        let h = make(recorder: FakeRecorder(pcm: SILENT))
        dictate(h)
        XCTAssertEqual(h.cues.value, ["hint: No speech heard"])
        XCTAssertEqual(h.notices.value, [])
        XCTAssertEqual(h.states.value.last, .idle)
    }

    func testShortTapNeverHints() {
        let h = make(recorder: FakeRecorder(pcm: SILENT))
        dictate(h, hold: 0.1)
        XCTAssertEqual(h.cues.value, [])
    }

    func testCleanupTimeoutPastesRawThenHintsWhy() {
        let h = make(cleaner: FakeCleaner(hang: true), config: PipelineConfig(cleanupTimeout: 0.05))
        dictate(h)
        XCTAssertEqual(h.cues.value, ["pasted", "hint: Pasted raw — cleanup timed out"])
    }

    func testEveryCleanupSkipHintsItsOwnReason() {
        let cases: [(cleaner: FakeCleaner, stt: FakeStt, hint: String)] = [
            (FakeCleaner(err: TestError(message: "boom")), FakeStt(), "Pasted raw — cleanup failed"),
            (FakeCleaner(out: ""), FakeStt(), "Pasted raw — cleanup output rejected"),
            (FakeCleaner(out: "a much longer rewrite than anything the speaker said"), FakeStt(),
                "Pasted raw — cleanup output rejected"),
            (FakeCleaner(out: "el perro es de la mesa con los"), FakeStt(text: "the dog is on the table with you"),
                "Pasted raw — cleanup output rejected"),
        ]
        for (cleaner, stt, hint) in cases {
            let h = make(stt: stt, cleaner: cleaner)
            dictate(h)
            XCTAssertEqual(h.cues.value, ["pasted", "hint: \(hint)"])
        }
    }

    func testSuccessfulCleanupCuesThePasteWithoutAHint() {
        let h = make()
        dictate(h)
        XCTAssertEqual(h.cues.value, ["pasted"])
    }

    func testCleanupDisabledPastesWithoutAHint() {
        let h = make()
        h.pipeline.cleanupEnabled = false
        dictate(h)
        XCTAssertEqual(h.cues.value, ["pasted"])
    }

    func testTooShortToCleanPastesWithoutAHint() {
        let h = make(stt: FakeStt(text: "just three words"))
        dictate(h)
        XCTAssertEqual(h.cues.value, ["pasted"])
    }

    func testNoCleanerPastesWithoutAHint() {
        let h = make(cleaner: nil)
        dictate(h)
        XCTAssertEqual(h.cues.value, ["pasted"])
    }

    func testAFailedPasteCuesNothingEvenWhenCleanupWasSkipped() {
        let h = make(
            cleaner: FakeCleaner(err: TestError(message: "boom")),
            paster: FakePaster(err: PasteError(message: "secure input")))
        dictate(h)
        XCTAssertEqual(h.cues.value, [])
    }

    func testAGuardedPasteThatOnlyCopiedCuesNothing() {
        let h = make(
            cleaner: FakeCleaner(err: TestError(message: "boom")),
            paster: FakePaster(err: PasteGuardError(notice: "Focus changed — text copied, press ⌘V")))
        dictate(h)
        XCTAssertEqual(h.cues.value, [])
    }

    func testTranscriptionFailureAndEmptyTranscriptCueNothing() {
        let failed = make(stt: FakeStt(err: SttError(message: "model missing")))
        dictate(failed)
        XCTAssertEqual(failed.cues.value, [])

        let empty = make(stt: FakeStt(text: ""))
        dictate(empty)
        XCTAssertEqual(empty.cues.value, [])
    }

    func testSttErrorSavesAudioAndNotifies() {
        let paster = FakePaster()
        let h = make(stt: FakeStt(err: SttError(message: "dead")), paster: paster)
        dictate(h)
        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(h.saved.value.count, 1)
        XCTAssertEqual(
            h.notices.value, [UserFacingError.transcriptionNotice(engineMessage: "dead")],
            "the notice is the mapped next step, not the engine text")
        XCTAssertEqual(h.states.value.last, .error)
    }

    /// Engine errors can echo paths or model ids; the notice may reach Notification Center, so only the log gets them.
    func testTranscriptionNoticeNeverEchoesTheEngineMessage() {
        let message = "model /Users/x/secret not found"
        let h = make(stt: FakeStt(err: SttError(message: message)))
        dictate(h)
        XCTAssertEqual(h.notices.value.count, 1)
        let notice = h.notices.value.first ?? ""
        XCTAssertFalse(notice.contains("/Users"), notice)
        XCTAssertFalse(notice.contains("secret"), notice)
        XCTAssertTrue(
            h.logs.value.contains { $0.hasPrefix("stt failed") && $0.contains(message) },
            "the reason must reach the log: \(h.logs.value)")
    }

    func testSttErrorIsTheTerminalStateForThatDictation() {
        let h = make(stt: FakeStt(err: SttError(message: "boom")))
        dictate(h)
        XCTAssertEqual(h.states.value, [.recording, .processing, .error])
    }

    func testNonSttErrorStillEndsIdle() {
        let h = make(stt: FakeStt(err: TestError(message: "boom")))
        dictate(h)
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
    }

    func testNothingTranscribedStillEndsIdle() {
        let h = make(stt: FakeStt(text: "  "))
        dictate(h)
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
    }

    func testSilentCaptureStillEndsIdle() {
        let h = make(recorder: FakeRecorder(pcm: SILENT))
        dictate(h)
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
    }

    func testShortHoldStillEmitsIdleFromKeyUp() {
        let h = make()
        dictate(h, hold: 0.1)
        XCTAssertEqual(h.states.value, [.recording, .idle])
    }

    func testNextKeyDownAfterAnErrorStartsRecording() {
        let h = make(stt: FakeStt(err: SttError(message: "boom")))
        dictate(h)
        h.pipeline.keyDown()
        XCTAssertEqual(h.states.value, [.recording, .processing, .error, .recording])
    }

    func testTrailingIdleNeverOverwritesANewerRecording() {
        let runner = ManualRunner()
        let h = make(runner: runner.run)
        dictate(h)                      // job 1 queued, not yet run
        h.pipeline.keyDown()            // job 2 is now recording
        runner.drain()                  // job 1 finishes while job 2 is held
        XCTAssertEqual(h.states.value, [.recording, .recording])
    }

    func testStaleSttErrorKeepsNoticeAndAudioButNotTheGlyph() {
        let runner = ManualRunner()
        let h = make(stt: FakeStt(err: SttError(message: "boom")), runner: runner.run)
        dictate(h)
        h.pipeline.keyDown()
        runner.drain()
        XCTAssertEqual(h.states.value.last, .recording)
        XCTAssertFalse(h.states.value.contains(.error))
        XCTAssertEqual(h.saved.value.count, 1)
        XCTAssertFalse(h.notices.value.isEmpty)
    }

    func testTheNewestJobStillEmitsItsTrailingIdle() {
        let runner = ManualRunner()
        let h = make(runner: runner.run)
        dictate(h)
        h.pipeline.keyDown()
        h.clock.t += 1.0
        h.pipeline.keyUp()              // job 2 queued behind job 1
        runner.drain()
        XCTAssertEqual(h.states.value, [.recording, .recording, .processing, .idle])
    }

    func testShortTapDuringProcessingKeepsTheErrorGlyph() {
        let runner = ManualRunner()
        let h = make(stt: FakeStt(err: SttError(message: "boom")), runner: runner.run)
        dictate(h)                      // job 1 queued, not yet run
        dictate(h, hold: 0.1)           // a discarded tap must not orphan job 1's failure
        runner.drain()
        XCTAssertEqual(h.states.value, [.recording, .recording, .idle, .processing, .error])
    }

    func testSttEmptyDiscardsWithNotice() {
        let paster = FakePaster()
        let h = make(stt: FakeStt(text: "  "), paster: paster)
        dictate(h)
        XCTAssertEqual(paster.pasted, [])
        XCTAssertFalse(h.notices.value.isEmpty)
    }

    func testPasteErrorNotifiesManualPaste() {
        let hist = History(maxLen: 10)
        let h = make(paster: FakePaster(err: PasteError(message: "secure input")), history: hist)
        dictate(h)
        XCTAssertTrue(h.notices.value.contains { $0.contains("⌘V") })
        XCTAssertEqual(hist.items().count, 1)
    }

    func testPasteGuardErrorSurfacesItsOwnNotice() {
        let hist = History(maxLen: 10)
        let h = make(paster: FakePaster(err: PasteGuardError(notice: "X")), history: hist)
        dictate(h)
        XCTAssertEqual(h.notices.value, ["X"])
        XCTAssertFalse(h.notices.value.contains("Paste failed — press ⌘V to paste manually"))
        // The text is on the clipboard and in history, so the dictation still counts.
        XCTAssertEqual(hist.items().count, 1)
    }

    func testPasteIsGivenTheAppFocusedAtKeyDown() {
        let paster = FakePaster()
        let h = make(paster: paster, frontmost: { 7 })
        dictate(h)
        XCTAssertEqual(paster.targets, [7])
    }

    func testPasteTargetIsNilWhenNoAppIsReported() {
        let paster = FakePaster()
        let h = make(paster: paster)
        dictate(h)
        XCTAssertEqual(paster.targets, [nil])
    }

    func testQueuedJobKeepsItsTargetWhenFocusMovesAndANewRecordingStarts() {
        let runner = ManualRunner()
        let paster = FakePaster()
        var front: pid_t? = 1
        let h = make(paster: paster, runner: runner.run, frontmost: { front })
        dictate(h)
        front = 2
        h.pipeline.keyDown()
        runner.drain()
        XCTAssertEqual(paster.targets, [1])
    }

    func testShortTapDoesNotRetargetTheQueuedJob() {
        let runner = ManualRunner()
        let paster = FakePaster()
        var front: pid_t? = 1
        let h = make(paster: paster, runner: runner.run, frontmost: { front })
        dictate(h)
        front = 2
        dictate(h, hold: 0.1)
        runner.drain()
        XCTAssertEqual(paster.targets, [1])
    }

    func testEachQueuedJobPastesToItsOwnKeyDownApp() {
        let runner = ManualRunner()
        let paster = FakePaster()
        var front: pid_t? = 1
        let h = make(paster: paster, runner: runner.run, frontmost: { front })
        dictate(h)
        front = 2
        dictate(h)
        runner.drain()
        XCTAssertEqual(paster.targets, [1, 2])
    }

    func testHistoryRecordsEngineAndRawFinal() {
        let hist = History(maxLen: 10)
        let h = make(history: hist)
        dictate(h)
        let r = hist.items()[0]
        XCTAssertEqual(r.engine, "parakeet")
        XCTAssertEqual(r.final, "hello there world")
    }

    func testEngineSwap() {
        let paster = FakePaster()
        let h = make(paster: paster)
        h.pipeline.setEngine(FakeStt(text: "desde whisper aquí cuatro"), name: "whisper")
        dictate(h)
        XCTAssertEqual(h.pipeline.engineName, "whisper")
        XCTAssertEqual(paster.pasted.count, 1)
    }

    func testCleanerSwap() {
        let paster = FakePaster()
        let h = make(paster: paster)
        let pipeline = h.pipeline

        // Baseline: the default cleaner's output is what gets pasted.
        dictate(h)
        XCTAssertEqual(paster.pasted.last, "hello there world")

        // Swap in a new cleaner with its own model name.
        pipeline.setCleaner(FakeCleaner(out: "new model text"), name: "new-model")
        dictate(h)
        XCTAssertEqual(paster.pasted.last, "new model text")   // new cleaner's output
        XCTAssertEqual(pipeline.cleanupModelName, "new-model")

        // Swap to nil: cleanup disabled, raw text pasted.
        pipeline.setCleaner(nil, name: "")
        dictate(h)
        XCTAssertEqual(paster.pasted.last, "so um hello there world")   // raw
        XCTAssertEqual(pipeline.cleanupModelName, "")

        // Engine is unaffected by cleaner swaps.
        XCTAssertEqual(pipeline.engineName, "parakeet")
    }

    func testDictationLogNamesTheCleanupModel() {
        let h = make()
        h.pipeline.setCleaner(FakeCleaner(out: "hello there world"), name: "gemma4")
        dictate(h)
        let line = h.logs.value.last ?? ""
        XCTAssertTrue(line.hasPrefix("dictation: engine=parakeet cleanupModel=gemma4 stt="), line)
        XCTAssertTrue(line.contains("cleaned=true"), line)
    }

    func testTwoDictationsFifo() {
        let paster = FakePaster()
        let h = make(paster: paster)
        dictate(h)
        dictate(h)
        XCTAssertEqual(paster.pasted.count, 2)
    }

    func testCleanupTranslationFallsBackToRaw() {
        let paster = FakePaster()
        let h = make(
            stt: FakeStt(text: "digamos que el deploy se hace el viernes antes de las cinco"),
            cleaner: FakeCleaner(out: "The deploy is done on Friday before five o'clock."),
            paster: paster
        )
        dictate(h)
        XCTAssertEqual(paster.pasted, ["digamos que el deploy se hace el viernes antes de las cinco"])
    }

    func testOnCleanedFiresWithCleanedTextOnSuccess() {
        let h = make()
        dictate(h)
        XCTAssertEqual(h.cleanedTexts.value, ["hello there world"])
    }

    func testOnCleanedNotFiredWhenCleanupDisabled() {
        let h = make()
        h.pipeline.cleanupEnabled = false
        dictate(h)
        XCTAssertEqual(h.cleanedTexts.value, [])
    }

    func testOnCleanedNotFiredOnCleanupError() {
        let h = make(cleaner: FakeCleaner(err: TestError(message: "boom")))
        dictate(h)
        XCTAssertEqual(h.cleanedTexts.value, [])
    }

    func testOnCleanedNotFiredBelowMinWords() {
        let h = make(stt: FakeStt(text: "just three words"))
        dictate(h)
        XCTAssertEqual(h.cleanedTexts.value, [])
    }

    func testOnCleanedNilIsSafe() {
        // The default-nil hook must not crash a successfully cleaned dictation.
        let paster = FakePaster()
        let clock = FakeClock()
        let pipeline = DictationPipeline(
            recorder: FakeRecorder(),
            stt: FakeStt(),
            cleaner: FakeCleaner(),
            paster: paster,
            history: History(maxLen: 10),
            config: PipelineConfig(),
            clock: { clock.t },
            runner: makeSyncRunner(),
            onState: { _ in },
            onNotice: { _ in },
            saveFailedAudio: { _ in }
        )
        pipeline.keyDown()
        clock.t += 1.0
        pipeline.keyUp()
        XCTAssertEqual(paster.pasted, ["hello there world"])
    }

    private var camelPair: [ReplacementPair] {
        [ReplacementPair(original: "camel", replacement: "kamal", addedAt: Date(timeIntervalSince1970: 0))]
    }

    func testReplacementAppliesWhenUtteranceIsTooShortToClean() {
        // The real-world bug: "deploy with camel" is 3 words, under the
        // minWords gate, so cleanup never ran and the dictionary never
        // applied. It must apply anyway.
        let paster = FakePaster()
        let cleaner = FakeCleaner()
        let h = make(
            stt: FakeStt(text: "deploy with camel"), cleaner: cleaner, paster: paster,
            pairs: camelPair)
        dictate(h)
        XCTAssertEqual(cleaner.calls, 0, "precondition: cleanup skipped")
        XCTAssertEqual(paster.pasted, ["deploy with kamal"])
    }

    func testReplacementAppliesWhenCleanupIsDisabled() {
        let paster = FakePaster()
        let h = make(stt: FakeStt(text: "so um deploy with camel today"), paster: paster, pairs: camelPair)
        h.pipeline.cleanupEnabled = false
        dictate(h)
        XCTAssertEqual(paster.pasted, ["so um deploy with kamal today"])
    }

    func testReplacementAppliesWhenCleanupFails() {
        let paster = FakePaster()
        let h = make(
            stt: FakeStt(text: "so um deploy with camel today"),
            cleaner: FakeCleaner(err: TestError(message: "boom")), paster: paster, pairs: camelPair)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["so um deploy with kamal today"])
    }

    func testReplacementIsReappliedAfterCleanup() {
        // Cleanup likes to capitalize; the pair's exact spelling wins.
        let paster = FakePaster()
        let h = make(
            stt: FakeStt(text: "so um deploy with camel today"),
            cleaner: FakeCleaner(out: "Deploy with Camel today."), paster: paster, pairs: camelPair)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["Deploy with kamal today."])
    }

    func testCleanerReceivesTheCorrectedTranscript() {
        // The model should read what the speaker said, not the mishearing.
        let cleaner = FakeCleaner()
        let h = make(stt: FakeStt(text: "so um deploy with camel today"), cleaner: cleaner, pairs: camelPair)
        dictate(h)
        XCTAssertEqual(cleaner.received, ["so um deploy with kamal today"])
    }

    // MARK: - Diagnostics: every degraded outcome leaves a line in scribe.log

    /// The log promises no dictated text: neither the transcript nor the cleaner's output may appear in any line.
    /// Strings under 4 characters are skipped, as they would match unrelated log text.
    private func assertNoDictatedText(
        _ h: Harness, stt: FakeStt, cleaner: FakeCleaner, file: StaticString = #filePath, line: UInt = #line
    ) {
        for secret in [stt.text, cleaner.out] where secret.count >= 4 {
            XCTAssertFalse(
                h.logs.value.contains { $0.contains(secret) },
                "dictated text reached the log: \(h.logs.value)", file: file, line: line)
        }
    }

    /// The `dictation:` summary of a single dictation run with `cleaner`.
    private func dictationLine(
        cleaner: FakeCleaner, stt: FakeStt = FakeStt(), config: PipelineConfig = PipelineConfig()
    ) -> String {
        let h = make(stt: stt, cleaner: cleaner, config: config)
        dictateBounded(h)
        assertNoDictatedText(h, stt: stt, cleaner: cleaner)
        return h.logs.value.last { $0.hasPrefix("dictation:") } ?? "<no dictation line: \(h.logs.value)>"
    }

    func testSttErrorIsLoggedWithItsMessage() {
        let h = make(stt: FakeStt(err: SttError(message: "model file missing")))
        dictate(h)
        XCTAssertTrue(
            h.logs.value.contains { $0.hasPrefix("stt failed") && $0.contains("model file missing") },
            "\(h.logs.value)")
    }

    func testSttDeadlineIsLogged() {
        let h = make(stt: FakeStt(hang: true), config: PipelineConfig(sttTimeout: 0.05))
        dictateBounded(h)
        XCTAssertTrue(
            h.logs.value.contains { $0.hasPrefix("stt failed") && $0.contains("timed out") },
            "\(h.logs.value)")
    }

    func testUnexpectedSttFailureIsLogged() {
        let h = make(stt: FakeStt(err: TestError(message: "odd failure")))
        dictate(h)
        XCTAssertTrue(
            h.logs.value.contains { $0.hasPrefix("stt failed") && $0.contains("odd failure") },
            "\(h.logs.value)")
    }

    func testCleanupDeadlineLogsTimeoutAsTheSkipReason() {
        let line = dictationLine(
            cleaner: FakeCleaner(hang: true), config: PipelineConfig(cleanupTimeout: 0.05))
        XCTAssertTrue(line.contains("cleaned=false"), line)
        XCTAssertTrue(line.hasSuffix(" cleanup_skip=timeout"), line)
    }

    func testCleanupErrorLogsErrorAsTheSkipReasonWithoutItsMessage() {
        // The backend sees the dictated text, so its error text could echo it: log the reason, never the message.
        let line = dictationLine(cleaner: FakeCleaner(err: TestError(message: "so um hello there world")))
        XCTAssertTrue(line.hasSuffix(" cleanup_skip=error"), line)
    }

    func testEmptyCleanupLogsEmptyAsTheSkipReason() {
        XCTAssertTrue(dictationLine(cleaner: FakeCleaner(out: "")).hasSuffix(" cleanup_skip=empty"))
    }

    func testOutOfBandCleanupLogsLengthAsTheSkipReason() {
        let line = dictationLine(cleaner: FakeCleaner(out: "a much longer rewrite than anything the speaker said"))
        XCTAssertTrue(line.hasSuffix(" cleanup_skip=length"), line)
    }

    func testLanguageFlipLogsLanguageAsTheSkipReason() {
        let line = dictationLine(
            cleaner: FakeCleaner(out: "el perro es de la mesa con los"),
            stt: FakeStt(text: "the dog is on the table with you"))
        XCTAssertTrue(line.hasSuffix(" cleanup_skip=language"), line)
    }

    func testSuccessfulCleanupLogsNoSkipReason() {
        let line = dictationLine(cleaner: FakeCleaner())
        XCTAssertTrue(line.contains("cleaned=true"), line)
        XCTAssertFalse(line.contains("cleanup_skip"), line)
    }

    // MARK: - Bounds: deadlines, queue age, hold limits

    func testHangingCleanerIsBoundedAndRawIsPasted() {
        let paster = FakePaster()
        let h = make(cleaner: FakeCleaner(hang: true), paster: paster, config: PipelineConfig(cleanupTimeout: 0.05))
        dictateBounded(h)
        XCTAssertEqual(paster.pasted.last, "so um hello there world")
        XCTAssertEqual(h.states.value.last, .idle)
    }

    func testTimedOutCleanupIsCancelledSoCooperativeBackendsReleaseTheModel() {
        let cancelled = expectation(description: "cleaner told to stop")
        let h = make(
            cleaner: FakeCleaner(delay: 5.0, onCancel: { cancelled.fulfill() }),
            config: PipelineConfig(cleanupTimeout: 0.05))
        dictateBounded(h)
        wait(for: [cancelled], timeout: 2.0)
    }

    func testHangingSttIsBoundedAndEndsInTheErrorState() {
        let paster = FakePaster()
        let h = make(stt: FakeStt(hang: true), paster: paster, config: PipelineConfig(sttTimeout: 0.05))
        dictateBounded(h)
        XCTAssertEqual(h.states.value.last, .error)
        XCTAssertEqual(h.states.value.filter { $0 == .idle }.count, 0)
        XCTAssertEqual(h.saved.value.count, 1)
        XCTAssertEqual(h.notices.value, ["Transcription timed out after 0 s — audio saved"])
        XCTAssertEqual(paster.pasted, [])
    }

    func testJobThatWaitedTooLongBehindThePreviousOneIsSkipped() {
        let runner = ManualRunner()
        let paster = FakePaster()
        let stt = FakeStt()
        let h = make(stt: stt, paster: paster, runner: runner.run)
        dictate(h)
        h.clock.t += 31
        runner.drain()
        XCTAssertEqual(h.notices.value, ["Dictation skipped — it waited 31 s behind the previous one"])
        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(stt.calls, 0)
        XCTAssertEqual(h.states.value, [.recording, .idle], "a skipped job must still release the glyph")
    }

    func testJobWithinTheQueueLimitIsProcessed() {
        let runner = ManualRunner()
        let paster = FakePaster()
        let h = make(paster: paster, runner: runner.run)
        dictate(h)
        h.clock.t += 29
        runner.drain()
        XCTAssertEqual(paster.pasted, ["hello there world"])
        XCTAssertTrue(h.notices.value.isEmpty)
    }

    func testSkippedStaleJobStaysQuietWhileANewerHoldIsRecording() {
        let runner = ManualRunner()
        let h = make(runner: runner.run)
        dictate(h)
        h.clock.t += 31
        h.pipeline.keyDown()
        runner.drain()
        XCTAssertEqual(h.states.value.last, .recording)
    }

    func testForceStopWhileArmedNoticesThenProcessesTheHold() {
        let paster = FakePaster()
        let h = make(paster: paster)
        h.pipeline.keyDown()
        h.clock.t += 120
        h.pipeline.forceStop()
        XCTAssertEqual(h.notices.value, ["Stopped after 2 min — release the key"])
        XCTAssertTrue(h.states.value.contains(.processing))
        XCTAssertEqual(paster.pasted, ["hello there world"])
    }

    func testReleasingTheKeyAfterForceStopStartsNoSecondJob() {
        let paster = FakePaster()
        let stt = FakeStt()
        let h = make(stt: stt, paster: paster)
        h.pipeline.keyDown()
        h.clock.t += 120
        h.pipeline.forceStop()
        h.pipeline.keyUp()
        XCTAssertEqual(stt.calls, 1)
        XCTAssertEqual(paster.pasted.count, 1)
    }

    func testForceStopWhileIdleIsANoOp() {
        let h = make()
        h.pipeline.forceStop()
        XCTAssertTrue(h.states.value.isEmpty)
        XCTAssertTrue(h.notices.value.isEmpty)
    }

    func testForceStopAfterTheHoldEndedIsANoOp() {
        let paster = FakePaster()
        let h = make(paster: paster)
        dictate(h)
        h.pipeline.forceStop()
        XCTAssertEqual(paster.pasted.count, 1)
        XCTAssertTrue(h.notices.value.isEmpty)
    }

    func testCancelHoldWhileArmedDiscardsTheAudioQuietly() {
        let recorder = FakeRecorder()
        let paster = FakePaster()
        let stt = FakeStt()
        let h = make(recorder: recorder, stt: stt, paster: paster)
        h.pipeline.keyDown()
        XCTAssertTrue(recorder.armed)
        h.clock.t += 5
        h.pipeline.cancelHold()
        XCTAssertFalse(recorder.armed)
        XCTAssertEqual(h.states.value, [.recording, .idle])
        XCTAssertEqual(stt.calls, 0)
        XCTAssertEqual(paster.pasted, [])
        XCTAssertTrue(h.notices.value.isEmpty)
    }

    func testReleasingTheKeyAfterCancelHoldIsANoOp() {
        let stt = FakeStt()
        let h = make(stt: stt)
        h.pipeline.keyDown()
        h.pipeline.cancelHold()
        h.clock.t += 5
        h.pipeline.keyUp()
        XCTAssertEqual(stt.calls, 0)
        XCTAssertEqual(h.states.value, [.recording, .idle])
    }

    func testCancelHoldWhileIdleIsANoOp() {
        let h = make()
        h.pipeline.cancelHold()
        XCTAssertTrue(h.states.value.isEmpty)
        XCTAssertTrue(h.notices.value.isEmpty)
    }

    /// Locks in: arm() failure notifies, stays idle, never reaches the STT engine.
    func testRecorderArmFailureSkipsRecording() {
        let stt = FakeStt()
        let recorder = FakeRecorder(armError: TestError(message: "mic grant missing"))
        let h = make(recorder: recorder, stt: stt)
        h.pipeline.keyDown()
        XCTAssertFalse(h.states.value.contains(.recording))
        XCTAssertEqual(h.notices.value, [UserFacingError.recordingNotice(error: "mic grant missing")])
        XCTAssertFalse(h.notices.value.joined().contains("mic grant missing"), "\(h.notices.value)")
        XCTAssertTrue(h.logs.value.contains("recorder arm failed: mic grant missing"), "\(h.logs.value)")
        h.clock.t += 1.0
        h.pipeline.keyUp()
        XCTAssertEqual(stt.calls, 0)
    }

    // MARK: - Audio enhancement (experimental, off by default)

    func testEnhancementIsOffByDefaultSoSttSeesTheRawCapture() {
        let stt = FakeStt()
        let enhancer = FakeEnhancer()
        let h = make(stt: stt, enhancer: enhancer)
        dictate(h)
        XCTAssertEqual(enhancer.calls, 0)
        XCTAssertEqual(stt.received, [VOICED])
    }

    func testEnhancementRunsBeforeSttWhenEnabled() {
        let stt = FakeStt()
        let cleaned = [Float](repeating: 0.5, count: 16000)
        let enhancer = FakeEnhancer(out: cleaned)
        let h = make(stt: stt, enhancer: enhancer, enhanceEnabled: true)
        dictate(h)
        XCTAssertEqual(enhancer.calls, 1)
        XCTAssertEqual(enhancer.received, [VOICED], "enhancer must see the raw capture")
        XCTAssertEqual(stt.received, [cleaned], "STT must see the enhanced audio, not the raw capture")
    }

    /// A failed denoise must not cost the dictation: fall back to the raw capture.
    func testEnhancementFailureFallsBackToRawAudio() {
        let stt = FakeStt()
        let enhancer = FakeEnhancer(err: TestError(message: "model download failed"))
        let h = make(stt: stt, enhancer: enhancer, enhanceEnabled: true)
        dictate(h)
        XCTAssertEqual(enhancer.calls, 1)
        XCTAssertEqual(stt.received, [VOICED])
        XCTAssertEqual(h.pipeline.engineName, "parakeet")
        XCTAssertTrue(h.notices.value.isEmpty, "a swallowed enhancement failure is not user-facing")
    }

    /// The enhanced copy is only a transcription input: a failed-audio save is for retrying the real capture.
    func testSttFailureAfterEnhancementSavesTheRawCapture() {
        let enhancer = FakeEnhancer(out: [Float](repeating: 0.5, count: 16000))
        let h = make(
            stt: FakeStt(err: SttError(message: "model file missing")), enhancer: enhancer, enhanceEnabled: true)
        dictate(h)
        XCTAssertEqual(enhancer.calls, 1)
        XCTAssertEqual(h.saved.value, [VOICED])
    }

    func testSttTimeExcludesEnhancementTimeAndBothAreLogged() {
        let clock = FakeClock()
        let enhancer = FakeEnhancer(onEnhance: { clock.t += 2.0 })
        let stt = FakeStt(onTranscribe: { clock.t += 1.0 })
        let h = make(stt: stt, enhancer: enhancer, enhanceEnabled: true, clock: clock)
        dictate(h)
        let line = h.logs.value.last { $0.hasPrefix("dictation:") } ?? "<no dictation line: \(h.logs.value)>"
        XCTAssertTrue(line.contains(" stt=1000ms "), line)
        XCTAssertTrue(line.contains(" enhance=2000ms "), line)
    }

    func testEnhanceIsLoggedAsZeroWhenEnhancementIsOff() {
        let h = make(enhancer: FakeEnhancer())
        dictate(h)
        let line = h.logs.value.last { $0.hasPrefix("dictation:") } ?? "<no dictation line: \(h.logs.value)>"
        XCTAssertTrue(line.contains(" enhance=0ms "), line)
    }

    // MARK: - Enhancement is bounded

    func testHangingEnhancerIsBoundedAndSttGetsTheRawCapture() {
        let stt = FakeStt()
        let paster = FakePaster()
        let h = make(
            stt: stt, paster: paster, config: PipelineConfig(enhanceTimeout: 0.05),
            enhancer: FakeEnhancer(hang: true), enhanceEnabled: true)
        dictateBounded(h)
        XCTAssertEqual(stt.received, [VOICED])
        XCTAssertEqual(paster.pasted.last, "hello there world")
        XCTAssertEqual(h.states.value.last, .idle)
        XCTAssertTrue(h.notices.value.isEmpty, "a skipped enhancement is not user-facing")
        let line = h.logs.value.last { $0.hasPrefix("dictation:") } ?? "<no dictation line: \(h.logs.value)>"
        XCTAssertTrue(line.contains(" enhance_skip=timeout"), line)
    }

    func testTimedOutEnhanceIsCancelledSoItStopsWorking() {
        let cancelled = expectation(description: "enhancer told to stop")
        let h = make(
            config: PipelineConfig(enhanceTimeout: 0.05),
            enhancer: FakeEnhancer(delay: 5.0, onCancel: { cancelled.fulfill() }), enhanceEnabled: true)
        dictateBounded(h)
        wait(for: [cancelled], timeout: 2.0)
    }

    func testEnhancerErrorLogsErrorAsTheSkipReasonAndTheCause() {
        let h = make(
            enhancer: FakeEnhancer(err: TestError(message: "model blew up")), enhanceEnabled: true)
        dictate(h)
        let line = h.logs.value.last { $0.hasPrefix("dictation:") } ?? "<no dictation line: \(h.logs.value)>"
        XCTAssertTrue(line.contains(" enhance_skip=error"), line)
        XCTAssertTrue(h.logs.value.contains("enhance failed: model blew up"), "\(h.logs.value)")
    }

    func testSuccessfulEnhancementLogsNoSkipReason() {
        let h = make(enhancer: FakeEnhancer(), enhanceEnabled: true)
        dictate(h)
        let line = h.logs.value.last { $0.hasPrefix("dictation:") } ?? "<no dictation line: \(h.logs.value)>"
        XCTAssertFalse(line.contains("enhance_skip"), line)
    }

    func testDisabledEnhancementLogsNoSkipReason() {
        let h = make(enhancer: FakeEnhancer(hang: true))
        dictateBounded(h)
        let line = h.logs.value.last { $0.hasPrefix("dictation:") } ?? "<no dictation line: \(h.logs.value)>"
        XCTAssertFalse(line.contains("enhance_skip"), line)
    }

    func testEnhanceTimeoutDefaultsToThreeSeconds() {
        XCTAssertEqual(PipelineConfig().enhanceTimeout, 3.0)
    }

    // MARK: - Stats

    func testStatsRecordACleanedDictation() {
        let clock = FakeClock()
        // 0.25 is exact in binary; 0.2 would make the millisecond truncation read 199.
        let h = make(stt: FakeStt(onTranscribe: { clock.t += 0.25 }), clock: clock)
        dictate(h)
        XCTAssertEqual(h.stats.value.count, 1)
        let stat = h.stats.value.first
        XCTAssertEqual(stat?.words, 3, "counted on what was pasted, not on the raw transcript")
        XCTAssertEqual(stat?.cleaned, true)
        XCTAssertEqual(stat?.rawFallback, false)
        XCTAssertEqual(stat?.sttMs, 250)
        XCTAssertNotNil(stat?.cleanupMs)
    }

    func testStatsRecordARawFallback() {
        let h = make(cleaner: FakeCleaner(hang: true), config: PipelineConfig(cleanupTimeout: 0.05))
        dictateBounded(h)
        XCTAssertEqual(h.stats.value.count, 1)
        let stat = h.stats.value.first
        XCTAssertEqual(stat?.cleaned, false)
        XCTAssertEqual(stat?.rawFallback, true)
        XCTAssertNotNil(stat?.cleanupMs, "the cleanup attempt ran, so its time counts")
        XCTAssertEqual(stat?.words, 5, "the raw transcript is what was pasted")
    }

    func testStatsRecordAShortDictationWithoutCleanup() {
        let h = make(stt: FakeStt(text: "hi there"))
        dictate(h)
        XCTAssertEqual(h.stats.value.count, 1)
        let stat = h.stats.value.first
        XCTAssertNil(stat?.cleanupMs, "cleanup never ran, so there is no cleanup time to report")
        XCTAssertEqual(stat?.rawFallback, false, "skipping a short utterance is not a fallback")
        XCTAssertEqual(stat?.cleaned, false)
        XCTAssertEqual(stat?.words, 2)
    }

    func testStatsSkipFailedTranscriptions() {
        let h = make(stt: FakeStt(err: SttError(message: "boom")))
        dictate(h)
        XCTAssertTrue(h.stats.value.isEmpty)
    }

    func testStatsSkipVoiceCommands() {
        let h = make(stt: FakeStt(text: "enter"), keyPresser: FakeKeyPresser())
        dictate(h)
        XCTAssertTrue(h.stats.value.isEmpty, "a command is not a dictation")
    }

    // MARK: - Voice commands

    func testWholeUtteranceReturnCommandPressesReturnInTheKeyDownApp() {
        let presser = FakeKeyPresser()
        let paster = FakePaster()
        let cleaner = FakeCleaner()
        let hist = History(maxLen: 10)
        let h = make(
            stt: FakeStt(text: "Send it."), cleaner: cleaner, paster: paster, history: hist,
            config: PipelineConfig(minWords: 1), frontmost: { 42 }, keyPresser: presser)
        dictate(h)
        XCTAssertEqual(presser.pressed, [.returnKey])
        XCTAssertEqual(presser.targets, [42])
        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(cleaner.calls, 0)
        XCTAssertTrue(hist.items().isEmpty, "a command is not a dictation")
        XCTAssertEqual(h.cues.value, ["pasted", "hint: Return sent"])
        XCTAssertTrue(h.logs.value.contains { $0.contains("command=return") }, "\(h.logs.value)")
        XCTAssertFalse(h.logs.value.contains { $0.contains("Send it") }, "the log must not echo the utterance")
        XCTAssertEqual(h.states.value.last, .idle)
    }

    func testACommandIsNeverOfferedToTheDictionaryHarvester() {
        let cleaner = FakeCleaner(out: "Enter.")
        let h = make(stt: FakeStt(text: "enter"), cleaner: cleaner, config: PipelineConfig(minWords: 1),
                     keyPresser: FakeKeyPresser())
        dictate(h)
        XCTAssertEqual(cleaner.calls, 0)
        XCTAssertEqual(h.cleanedTexts.value, [])

        // Control: the same utterance as text does reach the harvester, so the assertion above can fail.
        let control = make(stt: FakeStt(text: "enter"), cleaner: FakeCleaner(out: "Enter."),
                           config: PipelineConfig(minWords: 1), voiceCommands: false)
        dictate(control)
        XCTAssertEqual(control.cleanedTexts.value, ["Enter."])
    }

    func testNewLineAndNewParagraphPasteBreaks() {
        let lineKeys = FakeKeyPresser()
        let linePaster = FakePaster()
        let line = make(stt: FakeStt(text: "new line"), paster: linePaster, keyPresser: lineKeys)
        dictate(line)
        XCTAssertEqual(linePaster.pasted, ["\n"])
        XCTAssertEqual(lineKeys.pressed, [])
        XCTAssertEqual(line.cues.value, ["pasted", "hint: New line"])

        let paragraphKeys = FakeKeyPresser()
        let paragraphPaster = FakePaster()
        let paragraph = make(stt: FakeStt(text: "Nuevo párrafo."), paster: paragraphPaster, keyPresser: paragraphKeys)
        dictate(paragraph)
        XCTAssertEqual(paragraphPaster.pasted, ["\n\n"])
        XCTAssertEqual(paragraphKeys.pressed, [])
        XCTAssertEqual(paragraph.cues.value, ["pasted", "hint: New paragraph"])
    }

    func testBreaksAreHandedTheKeyDownApp() {
        let paster = FakePaster()
        let h = make(stt: FakeStt(text: "new line"), paster: paster, frontmost: { 9 }, keyPresser: FakeKeyPresser())
        dictate(h)
        XCTAssertEqual(paster.targets, [9])
    }

    func testUndoSendsCommandZ() {
        let presser = FakeKeyPresser()
        let paster = FakePaster()
        let h = make(stt: FakeStt(text: "scratch that"), paster: paster, keyPresser: presser)
        dictate(h)
        XCTAssertEqual(presser.pressed, [.commandZ])
        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(h.cues.value, ["pasted", "hint: Undo sent"])
    }

    func testCommandsOffMakesThePhraseOrdinaryText() {
        let presser = FakeKeyPresser()
        let paster = FakePaster()
        let h = make(stt: FakeStt(text: "Send it."), paster: paster, keyPresser: presser, voiceCommands: false)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["Send it."])
        XCTAssertEqual(presser.pressed, [])
    }

    func testTheCommandSwitchAppliesFromTheNextDictation() {
        let presser = FakeKeyPresser()
        let paster = FakePaster()
        let h = make(stt: FakeStt(text: "enter"), paster: paster, keyPresser: presser)
        h.pipeline.voiceCommandsEnabled = false
        dictate(h)
        XCTAssertEqual(paster.pasted, ["enter"])
        XCTAssertEqual(presser.pressed, [])

        h.pipeline.voiceCommandsEnabled = true
        dictate(h)
        XCTAssertEqual(paster.pasted, ["enter"], "the second dictation acted instead of pasting")
        XCTAssertEqual(presser.pressed, [.returnKey])
    }

    func testCommandInsideASentenceIsText() {
        let presser = FakeKeyPresser()
        let cleaner = FakeCleaner()
        let h = make(stt: FakeStt(text: "please send it to the team tomorrow"), cleaner: cleaner, keyPresser: presser)
        dictate(h)
        XCTAssertEqual(cleaner.calls, 1)
        XCTAssertEqual(presser.pressed, [])
    }

    func testCommandGuardFailureBecomesItsNotice() {
        let presser = FakeKeyPresser(err: PasteGuardError(notice: "Focus changed — Return not sent"))
        let h = make(stt: FakeStt(text: "enter"), keyPresser: presser)
        dictate(h)
        XCTAssertEqual(h.notices.value, ["Focus changed — Return not sent"])
        XCTAssertEqual(h.cues.value, [])
        XCTAssertEqual(h.states.value.last, .idle)
    }

    func testCommandWithoutAPresserFailsLoudly() {
        let h = make(stt: FakeStt(text: "enter"), keyPresser: nil)
        dictate(h)
        XCTAssertEqual(h.notices.value, ["Command failed — check log"])
        XCTAssertTrue(h.logs.value.contains { $0.hasPrefix("voice command failed (return)") }, "\(h.logs.value)")
        XCTAssertEqual(h.cues.value, [])
    }

    func testABreakThePasterRefusesFailsLoudly() {
        let paster = FakePaster(err: PasteError(message: "secure input"))
        let h = make(stt: FakeStt(text: "new line"), paster: paster, keyPresser: FakeKeyPresser())
        dictate(h)
        XCTAssertEqual(h.notices.value, ["Command failed — check log"])
        XCTAssertTrue(h.logs.value.contains { $0.hasPrefix("voice command failed (new_line)") }, "\(h.logs.value)")
        XCTAssertEqual(h.cues.value, [])
    }

    func testABreakTheGuardRefusesShowsTheGuardNotice() {
        let paster = FakePaster(err: PasteGuardError(notice: "Focus changed — text copied, press ⌘V"))
        let h = make(stt: FakeStt(text: "new line"), paster: paster, keyPresser: FakeKeyPresser())
        dictate(h)
        XCTAssertEqual(h.notices.value, ["Focus changed — text copied, press ⌘V"])
        XCTAssertEqual(h.cues.value, [])
    }

    func testAReplacementPairCannotDefuseACommand() {
        let presser = FakeKeyPresser()
        let h = make(
            stt: FakeStt(text: "Send it."),
            pairs: [ReplacementPair(original: "send it", replacement: "sent it", addedAt: Date(timeIntervalSince1970: 0))],
            keyPresser: presser)
        dictate(h)
        XCTAssertEqual(presser.pressed, [.returnKey])
    }

    // MARK: - Snippets

    private let address = "12 Elm St\nSpringfield"
    private var snippets: [Snippet] {
        [Snippet(trigger: "my address", expansion: address), Snippet(trigger: "my email", expansion: "e@example.com")]
    }

    func testWholeUtteranceSnippetExpandsUncleanedAndKeepsLineBreaks() {
        let cleaner = FakeCleaner()
        let paster = FakePaster()
        let hist = History(maxLen: 10)
        let h = make(
            stt: FakeStt(text: "my address."), cleaner: cleaner, paster: paster, history: hist, snippets: snippets)
        dictate(h)
        XCTAssertEqual(cleaner.calls, 0, "two words is under minWords, so the model never sees the trigger")
        XCTAssertEqual(paster.pasted, [address], "the period ASR added after the trigger must not trail a block")
        XCTAssertEqual(hist.items()[0].final, address)
    }

    func testSnippetInsideASentenceExpandsAfterCleanup() {
        let paster = FakePaster()
        let h = make(
            stt: FakeStt(text: "um write to my email please"),
            cleaner: FakeCleaner(out: "Write to my email, please."), paster: paster, snippets: snippets)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["Write to e@example.com, please."])
    }

    func testHarvesterNeverSeesAnExpansion() {
        let h = make(
            stt: FakeStt(text: "um write to my email please"),
            cleaner: FakeCleaner(out: "Write to my email, please."), snippets: snippets)
        dictate(h)
        XCTAssertEqual(h.cleanedTexts.value, ["Write to my email, please."])
    }

    func testStatsCountTheWordsSaidNotTheExpansion() {
        let h = make(stt: FakeStt(text: "my address."), snippets: snippets)
        dictate(h)
        XCTAssertEqual(h.stats.value.first?.words, 2)
    }

    func testNoSnippetsLeavesTextAlone() {
        let paster = FakePaster()
        let h = make(paster: paster)
        dictate(h)
        XCTAssertEqual(paster.pasted, ["hello there world"])
    }
}

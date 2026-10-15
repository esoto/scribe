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
        runner: ((@escaping () async -> Void) -> Void)? = nil
    ) -> Harness {
        let clock = FakeClock()
        let states = Box<PipelineState>()
        let notices = Box<String>()
        let saved = Box<[Float]>()
        let cleanedTexts = Box<String>()
        let logs = Box<String>()
        let pipeline = DictationPipeline(
            recorder: recorder,
            stt: stt,
            cleaner: cleaner,
            paster: paster,
            history: history,
            config: config,
            clock: { clock.t },
            runner: runner ?? makeSyncRunner(),
            onState: { states.append($0) },
            onNotice: { notices.append($0) },
            saveFailedAudio: { saved.append($0) },
            onLog: { logs.append($0) },
            onCleaned: { cleanedTexts.append($0) },
            replacementPairs: { pairs }
        )
        return Harness(
            pipeline: pipeline, clock: clock, states: states, notices: notices, saved: saved,
            cleanedTexts: cleanedTexts, logs: logs)
    }

    private func dictate(_ h: Harness, hold: Double = 1.0) {
        h.pipeline.keyDown()
        h.clock.t += hold
        h.pipeline.keyUp()
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

    func testSttErrorSavesAudioAndNotifies() {
        let paster = FakePaster()
        let h = make(stt: FakeStt(err: SttError(message: "dead")), paster: paster)
        dictate(h)
        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(h.saved.value.count, 1)
        XCTAssertFalse(h.notices.value.isEmpty)
        XCTAssertEqual(h.states.value.last, .error)
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

    /// Locks in: arm() failure notifies, stays idle, never reaches the STT engine.
    func testRecorderArmFailureSkipsRecording() {
        let stt = FakeStt()
        let recorder = FakeRecorder(armError: TestError(message: "mic grant missing"))
        let h = make(recorder: recorder, stt: stt)
        h.pipeline.keyDown()
        XCTAssertFalse(h.states.value.contains(.recording))
        XCTAssertFalse(h.notices.value.isEmpty)
        h.clock.t += 1.0
        h.pipeline.keyUp()
        XCTAssertEqual(stt.calls, 0)
    }
}

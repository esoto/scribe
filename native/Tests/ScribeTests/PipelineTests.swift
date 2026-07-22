import XCTest

/// Ported 1:1 from tests/test_pipeline.py (17 cases) plus one Swift-specific
/// addition for `RecorderLike.arm() throws`, a contract Python's recorder
/// never had (see PipelineTests.testRecorderArmFailureSkipsRecording).
final class PipelineTests: XCTestCase {
    // MARK: - Harness (mirrors tests/test_pipeline.py::make/dictate)

    private struct Harness {
        let pipeline: DictationPipeline
        let clock: FakeClock
        let states: Box<PipelineState>
        let notices: Box<String>
        let saved: Box<[Float]>
        let cleanedTexts: Box<String>
    }

    /// A runner that blocks the calling (test) thread until the async work
    /// completes — the deterministic equivalent of Python's `runner=lambda f: f()`.
    /// Swift's `_process` must be `async` (it awaits stt.transcribe/cleaner.clean
    /// and races a real Task.sleep for the cleanup timeout), so a plain
    /// synchronous call isn't possible; a semaphore bridges a `Task` back onto
    /// the calling thread without any `sleep`-based polling. Safe here because
    /// none of the pipeline's internals require the main actor.
    private func makeSyncRunner() -> (@escaping () async -> Void) -> Void {
        return { work in
            let sema = DispatchSemaphore(value: 0)
            Task {
                await work()
                sema.signal()
            }
            sema.wait()
        }
    }

    private func make(
        recorder: RecorderLike = FakeRecorder(),
        stt: SttEngine = FakeStt(),
        cleaner: CleanupBackend? = FakeCleaner(),
        paster: Pasting = FakePaster(),
        history: History = History(maxLen: 10),
        config: PipelineConfig = PipelineConfig()
    ) -> Harness {
        let clock = FakeClock()
        let states = Box<PipelineState>()
        let notices = Box<String>()
        let saved = Box<[Float]>()
        let cleanedTexts = Box<String>()
        let pipeline = DictationPipeline(
            recorder: recorder,
            stt: stt,
            cleaner: cleaner,
            paster: paster,
            history: history,
            config: config,
            clock: { clock.t },
            runner: makeSyncRunner(),
            onState: { states.append($0) },
            onNotice: { notices.append($0) },
            saveFailedAudio: { saved.append($0) },
            onCleaned: { cleanedTexts.append($0) }
        )
        return Harness(
            pipeline: pipeline, clock: clock, states: states, notices: notices, saved: saved,
            cleanedTexts: cleanedTexts)
    }

    private func dictate(_ h: Harness, hold: Double = 1.0) {
        h.pipeline.keyDown()
        h.clock.t += hold
        h.pipeline.keyUp()
    }

    // MARK: - Tests

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
        XCTAssertTrue(h.states.value.contains(.error))
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

    /// Swift-specific: `RecorderLike.arm() throws` has no equivalent in the
    /// Python contract (FakeRecorder.arm() never raises there). Locks in the
    /// behavior chosen for this native-only failure mode: notify, stay idle,
    /// never reach the STT engine.
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

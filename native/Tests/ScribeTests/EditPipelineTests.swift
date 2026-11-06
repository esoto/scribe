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
    func drain() {
        let jobs = queue
        queue.removeAll()
        for work in jobs { runBlocking(work) }
    }
}

final class EditPipelineTests: XCTestCase {
    // MARK: - Fixtures

    /// Long enough that "shorter" has room, with nothing capitalised past the sentence start.
    private static let selected =
        "I think that we should probably go ahead and schedule the meeting for sometime next week if that works for everybody involved."
    private static let shortened = "We should schedule the meeting next week if that works for everyone."
    /// Planted in every error message: none of them may reach a log line.
    private static let secret = "ZZ-secret-ZZ"

    private let snapshot: [PasteboardItemData] = [["public.utf8-plain-text": Data("the user's clipboard".utf8)]]
    private let copiedCount = 7

    private func selection(_ text: String = EditPipelineTests.selected) -> Selection {
        Selection(text: text, snapshot: snapshot, copiedChangeCount: copiedCount)
    }

    private struct Harness {
        let pipeline: EditPipeline
        let clock: FakeClock
        let states: Box<PipelineState>
        let notices: Box<String>
        let verdicts: Box<String>
        /// Failures, shown as ⚠ on the pill; a rejection is a verdict, not one of these.
        let problems: Box<String>
        let stats: Box<EditStat>
        let logs: Box<String>
        /// States, verdicts and problems in the order the sinks fired, as "state: …", "verdict: …" and "problem: …".
        let events: Box<String>
        let backend: FakeEditBackend
        let reader: FakeSelectionReader
        let replacer: FakeSelectionReplacer
        let stt: FakeStt
        let recorder: FakeRecorder
    }

    private func make(
        heard: String = "make it shorter",
        out: String = EditPipelineTests.shortened,
        backend: FakeEditBackend? = nil,
        noModel: Bool = false,
        reader: FakeSelectionReader? = nil,
        replacer: FakeSelectionReplacer = FakeSelectionReplacer(),
        stt: FakeStt? = nil,
        recorder: FakeRecorder = FakeRecorder(),
        config: PipelineConfig = PipelineConfig(),
        pairs: [ReplacementPair] = [],
        modelIsGemma4: Bool = false,
        runner: ((@escaping () async -> Void) -> Void)? = nil,
        clock: FakeClock = FakeClock()
    ) -> Harness {
        let states = Box<PipelineState>()
        let notices = Box<String>()
        let verdicts = Box<String>()
        let problems = Box<String>()
        let stats = Box<EditStat>()
        let logs = Box<String>()
        let events = Box<String>()
        let backend = backend ?? FakeEditBackend(out: out)
        let reader = reader ?? FakeSelectionReader(selection())
        let stt = stt ?? FakeStt(text: heard)
        let pipeline = EditPipeline(
            recorder: recorder,
            stt: stt,
            backend: { noModel ? nil : backend },
            modelIsGemma4: { modelIsGemma4 },
            selection: reader,
            paster: replacer,
            config: config,
            clock: { clock.t },
            frontmost: { 42 },
            replacementPairs: { pairs },
            sinks: EditSinks(
                onState: {
                    states.append($0)
                    events.append("state: \($0)")
                },
                onNotice: { notices.append($0) },
                onVerdict: {
                    verdicts.append($0)
                    events.append("verdict: \($0)")
                },
                onProblem: {
                    problems.append($0)
                    events.append("problem: \($0)")
                },
                onStat: { stats.append($0) },
                runner: runner ?? { work in runBlocking(work) }),
            onLog: { logs.append($0) })
        return Harness(
            pipeline: pipeline, clock: clock, states: states, notices: notices, verdicts: verdicts, problems: problems,
            stats: stats, logs: logs, events: events, backend: backend, reader: reader, replacer: replacer, stt: stt,
            recorder: recorder)
    }

    private func edit(_ h: Harness, hold: Double = 1.0) {
        h.pipeline.keyDown()
        h.clock.t += hold
        h.pipeline.keyUp()
    }

    /// Nothing the user selected, said or got back may appear in a log line, whichever way the edit ended.
    private func assertNoTextInTheLog(
        _ h: Harness, extra: [String] = [], file: StaticString = #filePath, line: UInt = #line
    ) {
        let needles =
            [
                "schedule the meeting", "everybody", "everyone", "make it", "purple", "Rewrite it", "Here's",
                EditPipelineTests.secret,
            ] + extra
        for entry in h.logs.value {
            for needle in needles {
                XCTAssertFalse(entry.contains(needle), "\(needle) leaked into: \(entry)", file: file, line: line)
            }
        }
    }

    // MARK: - The accepted edit

    func testAcceptedEditPastesOverTheSelectionAndRestoresTheOriginalClipboard() {
        let clock = FakeClock()
        let h = make(
            backend: FakeEditBackend(out: Self.shortened, onEdit: { clock.t += 0.5 }),
            stt: FakeStt(text: "make it shorter", onTranscribe: { clock.t += 0.25 }), clock: clock)

        edit(h)

        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
        XCTAssertEqual(h.replacer.replaced.count, 1)
        XCTAssertEqual(h.replacer.replaced.first?.text, Self.shortened)
        XCTAssertEqual(h.replacer.replaced.first?.target, 42)
        XCTAssertEqual(h.replacer.replaced.first?.snapshot, snapshot, "the clipboard from before the ⌘C is what comes back")
        XCTAssertEqual(h.replacer.replaced.first?.copiedChangeCount, copiedCount)
        XCTAssertTrue(h.replacer.restored.isEmpty, "the paste restores the clipboard itself")
        XCTAssertEqual(h.verdicts.value, ["Shorter"])
        XCTAssertEqual(h.notices.value, [])
        XCTAssertEqual(
            h.stats.value, [EditStat(verb: .shorter, sttMs: 250, editMs: 500, accepted: true, rejection: nil)])
        XCTAssertEqual(h.logs.value.count, 1)
        XCTAssertEqual(
            h.logs.value.first,
            "edit: engine=parakeet verb=shorter stt_ms=250 edit_ms=500 in_chars=\(Self.selected.count) out_chars=\(Self.shortened.count)")
        assertNoTextInTheLog(h)
    }

    func testTheBackendGetsTheTrimmedSelectionAndTheVerbsInstruction() {
        let h = make(heard: "Make it formal.", out: "We should arrange the meeting for next week, if that suits everyone involved.")

        edit(h)

        XCTAssertEqual(h.backend.edits.count, 1)
        XCTAssertEqual(h.backend.edits.first?.instruction, EditPrompt.instruction(verb: .formal, selection: Self.selected))
        XCTAssertTrue(h.backend.edits.first?.instruction.hasPrefix(EditVerb.formal.instruction) == true)
        XCTAssertEqual(h.backend.edits.first?.text, Self.selected)
        XCTAssertEqual(h.reader.targets.count, 1)
        XCTAssertEqual(h.reader.targets.first, 42, "the selection is read in the app that had focus at key-down")
    }

    func testTheVerdictIsReportedBeforeTheFinalIdle() {
        let h = make()

        edit(h)

        XCTAssertEqual(
            h.events.value, ["state: recording", "state: processing", "verdict: Shorter", "state: idle"],
            "the pill keeps a verdict only if it arrives before the idle")
    }

    func testAProblemIsReportedBeforeTheFinalIdleToo() {
        let h = make(stt: FakeStt(err: SttError(message: Self.secret)))

        edit(h)

        XCTAssertEqual(
            h.events.value,
            ["state: recording", "state: processing", "problem: Edit failed — transcription", "state: idle"],
            "the pill keeps a problem only if it arrives before the idle")
    }

    func testMaxTokensFollowsTheVerb() {
        let cases: [(utterance: String, verb: EditVerb)] = [
            ("make it shorter", .shorter), ("fix the grammar", .fixGrammar), ("make it formal", .formal),
            ("make it casual", .casual), ("make it a list", .list), ("translate to Spanish", .toSpanish),
            ("translate to English", .toEnglish),
        ]
        for (utterance, verb) in cases {
            let h = make(heard: utterance)
            edit(h)
            XCTAssertEqual(
                h.backend.edits.first?.maxTokens,
                EditPrompt.maxTokens(verb: verb, inputTokens: Self.selected.count / 4), utterance)
        }
    }

    func testDictionaryPairsApplyToTheInstruction() {
        let pair = ReplacementPair(original: "shorted", replacement: "shorter", addedAt: Date())
        let h = make(heard: "make it shorted", pairs: [pair])

        edit(h)

        XCTAssertEqual(h.backend.edits.first?.instruction, EditPrompt.instruction(verb: .shorter, selection: Self.selected))
        XCTAssertTrue(h.backend.edits.first?.instruction.hasPrefix(EditVerb.shorter.instruction) == true)
        XCTAssertEqual(h.verdicts.value, ["Shorter"])
    }

    func testAnEditEngineSwapAppliesFromTheNextEdit() {
        let h = make(heard: "make it shorter", out: "We should arrange the meeting for next week, if that suits everyone involved.")
        h.pipeline.setEngine(FakeStt(text: "make it formal"), name: "whisper")

        edit(h)

        XCTAssertEqual(h.backend.edits.first?.instruction, EditPrompt.instruction(verb: .formal, selection: Self.selected))
        XCTAssertTrue(h.backend.edits.first?.instruction.hasPrefix(EditVerb.formal.instruction) == true)
        XCTAssertTrue(h.logs.value.first?.contains("engine=whisper") == true, "\(h.logs.value)")
    }

    // MARK: - Nothing to edit

    func testNothingSelectedStopsBeforeTranscribing() {
        let h = make(reader: FakeSelectionReader(nil))

        edit(h)

        XCTAssertEqual(h.stt.calls, 0)
        XCTAssertEqual(h.backend.edits.count, 0)
        XCTAssertEqual(h.verdicts.value, ["Nothing selected"])
        XCTAssertEqual(h.problems.value, [], "nothing selected is an answer, not a failure")
        XCTAssertTrue(h.replacer.replaced.isEmpty)
        XCTAssertTrue(h.replacer.restored.isEmpty, "the reader already put the clipboard back, or never touched it")
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
        XCTAssertTrue(h.stats.value.isEmpty)
    }

    func testUnknownInstructionIsNotAnEditAndTheClipboardComesBack() {
        let h = make(heard: "make it purple")

        edit(h)

        XCTAssertEqual(h.verdicts.value, ["Not an edit — say shorter, formal, to Spanish…"])
        XCTAssertEqual(h.problems.value, [])
        XCTAssertEqual(h.backend.edits.count, 0)
        XCTAssertTrue(h.replacer.replaced.isEmpty)
        XCTAssertEqual(h.replacer.restored.count, 1)
        XCTAssertEqual(h.replacer.restored.first?.snapshot, snapshot)
        XCTAssertEqual(h.replacer.restored.first?.copiedChangeCount, copiedCount)
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
        XCTAssertTrue(h.stats.value.isEmpty, "a phrase that is no verb is not an edit")
        assertNoTextInTheLog(h)
    }

    func testSilenceIsNoSpeechAndCopiesNothing() {
        let h = make(recorder: FakeRecorder(pcm: SILENT))

        edit(h)

        XCTAssertEqual(h.verdicts.value, [DictationPipeline.noSpeechHint])
        XCTAssertEqual(h.problems.value, [])
        XCTAssertEqual(h.reader.reads, 0, "no ⌘C for a hold that captured nothing")
        XCTAssertEqual(h.stt.calls, 0)
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
    }

    func testNoModelLoadedIsAProblem() {
        let h = make(noModel: true)

        edit(h)

        XCTAssertEqual(h.problems.value, ["No cleanup model — pick one in Settings › Models"])
        XCTAssertEqual(h.verdicts.value, [])
        XCTAssertTrue(h.replacer.replaced.isEmpty)
        XCTAssertEqual(h.replacer.restored.count, 1)
        XCTAssertTrue(h.stats.value.isEmpty)
    }

    // MARK: - Rejections

    private func assertRejected(
        out: String, as expected: EditRejection, modelIsGemma4: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let h = make(out: out, modelIsGemma4: modelIsGemma4)

        edit(h)

        XCTAssertTrue(h.replacer.replaced.isEmpty, "a rejected result is never pasted", file: file, line: line)
        XCTAssertEqual(
            h.verdicts.value, [EditGates.pillReason(expected, modelIsGemma4: modelIsGemma4)], file: file, line: line)
        XCTAssertEqual(h.problems.value, [], "a rejection is a verdict (◦), not a failure (⚠)", file: file, line: line)
        XCTAssertEqual(h.stats.value.count, 1, file: file, line: line)
        XCTAssertEqual(h.stats.value.first?.accepted, false, file: file, line: line)
        XCTAssertEqual(h.stats.value.first?.rejection, expected, file: file, line: line)
        XCTAssertEqual(h.stats.value.first?.verb, .shorter, file: file, line: line)
        XCTAssertEqual(h.replacer.restored.count, 1, "the clipboard the ⌘C displaced comes back", file: file, line: line)
        XCTAssertEqual(h.replacer.restored.first?.snapshot, snapshot, file: file, line: line)
        XCTAssertEqual(h.replacer.restored.first?.copiedChangeCount, copiedCount, file: file, line: line)
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle], file: file, line: line)
        XCTAssertEqual(h.logs.value.count, 1, file: file, line: line)
        XCTAssertTrue(
            h.logs.value.first?.hasPrefix("edit: engine=parakeet verb=shorter rejected=\(expected.rawValue) ") == true,
            "\(h.logs.value)", file: file, line: line)
        assertNoTextInTheLog(h)
    }

    func testAnEmptyResultIsRejected() {
        assertRejected(out: "   ", as: .empty)
    }

    func testAnAnswerInsteadOfAnEditIsRejected() {
        assertRejected(out: "Here's a shorter version: We should schedule the meeting next week.", as: .answered)
    }

    func testAResultOutsideTheLengthBandIsRejected() {
        assertRejected(
            out: "I think that we should probably go ahead and schedule the meeting for sometime next week if that works for everybody.",
            as: .length)
    }

    func testAResultInTheOtherLanguageIsRejected() {
        assertRejected(out: "Deberíamos programar la reunión para la próxima semana si a todos les conviene.", as: .language)
    }

    func testAResultThatAddsSomethingNewIsRejected() {
        assertRejected(out: "We should schedule the meeting next week for 15 people.", as: .newFacts)
    }

    func testTheRejectionHintIsLeftOutWhenTheActiveModelIsGemma4() {
        assertRejected(out: "   ", as: .empty, modelIsGemma4: true)
        XCTAssertFalse(EditGates.pillReason(.empty, modelIsGemma4: true).contains("Gemma 4"))
        XCTAssertTrue(EditGates.pillReason(.empty, modelIsGemma4: false).contains("Gemma 4"))
    }

    func testTimeoutIsARejection() {
        let h = make(backend: FakeEditBackend(hang: true), config: PipelineConfig(cleanupTimeout: 0.05))

        edit(h)

        XCTAssertEqual(h.verdicts.value, [EditGates.pillReason(.timeout, modelIsGemma4: false)])
        XCTAssertEqual(h.problems.value, [], "a timeout is a gate rejection, not a failure")
        XCTAssertTrue(h.replacer.replaced.isEmpty)
        XCTAssertEqual(h.stats.value.first?.rejection, .timeout)
        XCTAssertEqual(h.stats.value.first?.accepted, false)
        XCTAssertEqual(h.replacer.restored.count, 1)
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
        assertNoTextInTheLog(h)
    }

    /// Gemma 3 needed 10.35 s for a 200-word translation against the 10.5 s a dictation deadline gives that length, so an
    /// edit grows 0.045 s a word past 50: 200 words get 12.75 s. The base and the 20 s cap are dictation's.
    func testTheEditDeadlineGrowsFortyFiveMillisecondsAWordPastFifty() {
        XCTAssertEqual(EditPipeline.secondsPerWordOverFifty, 0.045)
        XCTAssertEqual(EditPipeline.deadline(words: 0, base: 6), 6)
        XCTAssertEqual(EditPipeline.deadline(words: 50, base: 6), 6)
        XCTAssertEqual(EditPipeline.deadline(words: 51, base: 6), 6.045, accuracy: 1e-9)
        XCTAssertEqual(EditPipeline.deadline(words: 200, base: 6), 12.75, accuracy: 1e-9)
        XCTAssertEqual(DictationPipeline.cleanupDeadline(words: 200, base: 6), 10.5, accuracy: 1e-9, "dictation keeps its own slope")
    }

    func testTheEditDeadlineIsStillCappedAtTwentySecondsAndNeverBelowALargerBase() {
        XCTAssertEqual(EditPipeline.deadline(words: 1000, base: 6), 20)
        XCTAssertEqual(EditPipeline.deadline(words: 1000, base: 30), 30)
        XCTAssertEqual(EditPipeline.deadline(words: 5, base: 30), 30)
        XCTAssertLessThan(EditPipeline.deadline(words: 100_000, base: PipelineConfig().cleanupTimeout), PipelineConfig().queueMaxAge)
    }

    /// The call site, not just the function: 80 words with a 0.05 s base get 1.4 s at 0.045 s a word and only 0.95 s at
    /// dictation's 0.03, and the model takes 1.15 s.
    func testAnEditOfEightyWordsGetsTheEditSlopeAtTheCallSite() {
        let words = Array(repeating: "we shipped the build today", count: 16).joined(separator: " ")
        XCTAssertEqual(words.split(separator: " ").count, 80)
        let h = make(
            heard: "fix the grammar",
            backend: FakeEditBackend(out: words, delay: 1.15), reader: FakeSelectionReader(selection(words)),
            config: PipelineConfig(cleanupTimeout: 0.05))

        edit(h)

        XCTAssertEqual(h.verdicts.value, ["Fix grammar"], "a 0.03 s slope would have timed this edit out")
        XCTAssertEqual(h.stats.value.first?.accepted, true)
        XCTAssertEqual(h.replacer.replaced.count, 1)
    }

    // MARK: - The language hint

    func testAnEnglishSelectionReachesTheModelWithAnEnglishHint() {
        let h = make(heard: "make it formal")

        edit(h)

        XCTAssertEqual(
            h.backend.edits.first?.instruction,
            "Rewrite it in a formal register. The text is in English; answer in English.")
    }

    func testASpanishSelectionReachesTheModelWithASpanishHint() {
        let spanish = "El informe es para el martes y lo vamos a mandar a todo el equipo después de la reunión."
        let h = make(heard: "hazlo informal", reader: FakeSelectionReader(selection(spanish)))

        edit(h)

        XCTAssertEqual(
            h.backend.edits.first?.instruction,
            "Rewrite it in a casual, friendly register. The text is in Spanish; answer in Spanish.")
        XCTAssertEqual(h.backend.edits.first?.text, spanish, "the hint is in the instruction; the text goes through untouched")
    }

    func testATranslationReachesTheModelWithoutAHint() {
        let h = make(heard: "translate to Spanish")

        edit(h)

        XCTAssertEqual(h.backend.edits.first?.instruction, EditVerb.toSpanish.instruction)
    }

    func testASelectionThatScoresZeroReachesTheModelWithoutAHint() {
        let h = make(heard: "make it shorter", reader: FakeSelectionReader(selection("¡Buenos días a todos!")))

        edit(h)

        XCTAssertEqual(h.backend.edits.first?.instruction, EditVerb.shorter.instruction)
    }

    // MARK: - Failures on the way

    func testFocusMovedFallsBackToCopyOnlyWithTheNotice() {
        let h = make(replacer: FakeSelectionReplacer(err: PasteGuardError(notice: "Focus changed — text copied, press ⌘V")))

        edit(h)

        XCTAssertEqual(h.notices.value, ["Focus changed — text copied, press ⌘V"])
        XCTAssertEqual(h.verdicts.value, [], "the pill must not claim an edit that was not pasted")
        XCTAssertEqual(h.problems.value, [], "the copy-only fallback is the notice's job")
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
        XCTAssertEqual(h.stats.value.first?.accepted, true, "the result passed the gates")
        XCTAssertTrue(h.replacer.restored.isEmpty, "the edited text stays on the clipboard for the manual ⌘V")
    }

    func testAnyOtherPasteFailureAsksForAManualPaste() {
        let h = make(replacer: FakeSelectionReplacer(err: PasteError(message: "secure input \(Self.secret)")))

        edit(h)

        XCTAssertEqual(h.notices.value, ["Edit failed — press ⌘V to paste manually"])
        XCTAssertEqual(h.problems.value, ["Edit failed — press ⌘V to paste manually"])
        XCTAssertEqual(h.verdicts.value, [])
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
        assertNoTextInTheLog(h)
    }

    func testARefusedCopyIsTheGuardsNoticeAndTouchesNothing() {
        let h = make(
            reader: FakeSelectionReader(nil, err: PasteGuardError(notice: "Accessibility is off — ⌘C not sent")))

        edit(h)

        XCTAssertEqual(h.notices.value, ["Accessibility is off — ⌘C not sent"])
        XCTAssertEqual(h.verdicts.value, [])
        XCTAssertEqual(h.problems.value, [])
        XCTAssertEqual(h.stt.calls, 0)
        XCTAssertTrue(h.replacer.restored.isEmpty, "the copy never happened")
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
    }

    func testAnUnexpectedReadFailureIsLoggedByTypeOnly() {
        let h = make(reader: FakeSelectionReader(nil, err: TestError(message: Self.secret)))

        edit(h)

        XCTAssertEqual(h.problems.value, ["Edit failed — check log"])
        XCTAssertEqual(h.verdicts.value, [])
        XCTAssertTrue(h.logs.value.contains { $0.contains("TestError") }, "\(h.logs.value)")
        XCTAssertEqual(h.stt.calls, 0)
        assertNoTextInTheLog(h)
    }

    func testATranscriptionFailureRestoresTheClipboardAndLogsOnlyItsType() {
        let h = make(stt: FakeStt(err: SttError(message: Self.secret)))

        edit(h)

        XCTAssertEqual(h.problems.value, ["Edit failed — transcription"])
        XCTAssertEqual(h.verdicts.value, [])
        XCTAssertEqual(h.replacer.restored.count, 1)
        XCTAssertTrue(h.replacer.replaced.isEmpty)
        XCTAssertEqual(h.backend.edits.count, 0)
        XCTAssertTrue(h.logs.value.contains { $0.contains("SttError") }, "\(h.logs.value)")
        assertNoTextInTheLog(h)
    }

    func testATranscriptionTimeoutIsAFailureToo() {
        let h = make(stt: FakeStt(hang: true), config: PipelineConfig(sttTimeout: 0.05))

        edit(h)

        XCTAssertEqual(h.problems.value, ["Edit failed — transcription"])
        XCTAssertEqual(h.replacer.restored.count, 1)
        XCTAssertEqual(h.states.value, [.recording, .processing, .idle])
    }

    func testABackendFailureRestoresTheClipboardAndLogsOnlyItsType() {
        let h = make(backend: FakeEditBackend(err: CleanupError(message: Self.secret)))

        edit(h)

        XCTAssertEqual(h.problems.value, ["Edit failed — check log"])
        XCTAssertEqual(h.verdicts.value, [])
        XCTAssertEqual(h.replacer.restored.count, 1)
        XCTAssertTrue(h.replacer.replaced.isEmpty)
        XCTAssertTrue(h.stats.value.isEmpty)
        XCTAssertTrue(h.logs.value.contains { $0.contains("CleanupError") }, "\(h.logs.value)")
        assertNoTextInTheLog(h)
    }

    // MARK: - Holds

    func testAShortTapIsDiscarded() {
        let h = make()

        edit(h, hold: 0.1)

        XCTAssertEqual(h.states.value, [.recording, .idle])
        XCTAssertEqual(h.reader.reads, 0)
        XCTAssertEqual(h.stt.calls, 0)
        XCTAssertTrue(h.verdicts.value.isEmpty)
        XCTAssertFalse(h.recorder.armed)
        XCTAssertFalse(h.pipeline.isArmed)
    }

    func testTheHoldThresholdCanBeChangedAtRuntime() {
        let h = make()
        edit(h, hold: 0.2)
        XCTAssertEqual(h.stt.calls, 0, "0.2 s is a tap at the default 0.3 s")

        h.pipeline.setHoldThreshold(0.1)
        edit(h, hold: 0.2)

        XCTAssertEqual(h.stt.calls, 1)
    }

    func testKeyDownArmsAndKeyUpDisarms() {
        let h = make()
        h.pipeline.keyDown()
        XCTAssertTrue(h.pipeline.isArmed)
        XCTAssertTrue(h.recorder.armed)
        h.clock.t += 1
        h.pipeline.keyUp()
        XCTAssertFalse(h.pipeline.isArmed)
        XCTAssertFalse(h.recorder.armed)
    }

    func testARecorderThatWillNotStartIsANoticeAndNothingIsArmed() {
        let failure = TestError(message: "no input device")
        let h = make(recorder: FakeRecorder(armError: failure))

        h.pipeline.keyDown()

        XCTAssertFalse(h.pipeline.isArmed)
        XCTAssertEqual(h.notices.value, [UserFacingError.recordingNotice(error: "\(failure)")])
        XCTAssertEqual(h.problems.value, [UserFacingError.recordingNotice(error: "\(failure)")])
        XCTAssertEqual(h.states.value, [])
        h.pipeline.keyUp()
        XCTAssertEqual(h.reader.reads, 0)
    }

    func testARecorderFailureIsLoggedByTypeOnly() {
        let h = make(recorder: FakeRecorder(armError: TestError(message: Self.secret)))

        h.pipeline.keyDown()

        XCTAssertEqual(h.logs.value, ["recorder arm failed: TestError"])
        assertNoTextInTheLog(h)
    }

    func testForceStopEndsTheHoldWithTheWatchdogNoticeAndStillEdits() {
        let h = make()
        h.pipeline.keyDown()
        h.clock.t += 130

        h.pipeline.forceStop()

        XCTAssertEqual(h.notices.value, ["Stopped after 2 min — release the key"])
        XCTAssertFalse(h.recorder.armed)
        XCTAssertEqual(h.verdicts.value, ["Shorter"], "what was said before the stop is still an edit")
    }

    func testForceStopCarriesACustomNotice() {
        let h = make()
        h.pipeline.keyDown()
        h.clock.t += 1

        h.pipeline.forceStop(notice: "Stopped — release the key")

        XCTAssertEqual(h.notices.value, ["Stopped — release the key"])
    }

    func testForceStopAndCancelHoldDoNothingWhenNothingIsHeld() {
        let h = make()

        h.pipeline.forceStop()
        h.pipeline.cancelHold()

        XCTAssertEqual(h.notices.value, [])
        XCTAssertEqual(h.states.value, [])
    }

    func testCancelHoldReleasesTheRecorderAndReadsNothing() {
        let h = make()
        h.pipeline.keyDown()

        h.pipeline.cancelHold()

        XCTAssertFalse(h.recorder.armed)
        XCTAssertFalse(h.pipeline.isArmed)
        XCTAssertEqual(h.states.value, [.recording, .idle])
        XCTAssertEqual(h.reader.reads, 0)
        XCTAssertEqual(h.stt.calls, 0)
        h.pipeline.keyUp()
        XCTAssertEqual(h.reader.reads, 0, "a cancelled hold's release is not an edit")
    }

    // MARK: - Queueing

    func testAnEditThatWaitedTooLongIsDroppedWithoutCopyingAnything() {
        let runner = ManualRunner()
        let h = make(runner: runner.run)
        edit(h)
        h.clock.t += 31

        runner.drain()

        XCTAssertEqual(h.notices.value, ["Edit skipped — it waited 31 s behind the previous one"])
        XCTAssertEqual(h.problems.value, ["Edit skipped — it waited 31 s behind the previous one"])
        XCTAssertEqual(h.reader.reads, 0, "a stale edit must not ⌘C into whatever has focus now")
        XCTAssertEqual(h.states.value, [.recording, .idle], "dropped before it ever shows ⋯")
    }

    func testASecondEditQueuedBehindTheFirstShowsProcessingAtOnce() {
        let runner = ManualRunner()
        let h = make(runner: runner.run)
        edit(h)
        edit(h)
        XCTAssertEqual(h.states.value, [.recording, .recording, .processing])

        runner.drain()

        XCTAssertEqual(h.states.value, [.recording, .recording, .processing, .processing, .idle])
        XCTAssertEqual(h.reader.reads, 2)
        XCTAssertEqual(h.verdicts.value, ["Shorter", "Shorter"])
    }

    func testAnEarlierJobsStatesLeaveTheHoldInProgressAlone() {
        let runner = ManualRunner()
        let h = make(runner: runner.run)
        edit(h)
        h.pipeline.keyDown()

        runner.drain()

        XCTAssertEqual(h.states.value, [.recording, .recording], "the first job's ⋯ and idle would blank the hold's ●")
        XCTAssertEqual(h.verdicts.value, ["Shorter"], "its verdict still counts")
        h.clock.t += 1
        h.pipeline.keyUp()
        runner.drain()
        XCTAssertEqual(h.states.value, [.recording, .recording, .processing, .idle])
    }

    // MARK: - With the real paster: an edit right after a dictation

    private final class CopyKeys: KeyPressing {
        let onPress: () -> Void
        init(onPress: @escaping () -> Void) { self.onPress = onPress }
        func press(_ key: SyntheticKey, target: pid_t?) throws { onPress() }
    }

    func testAnEditReleasedShortlyAfterADictationWaitsOutItsRestoreAndNeverPastesTheUsersClipboard() throws {
        let text = "public.utf8-plain-text"
        let usersClipboard: [PasteboardItemData] = [[text: Data("the user's clipboard".utf8)]]
        let pb = PasteCoreTests.FakePasteboard(items: usersClipboard)
        let sched = PasteCoreTests.FakeScheduler()
        let clock = FakeClock()
        let sleeps = Box<Double>()
        let restoredAt = Box<Double>()
        let pastedByCommandV = Box<String>()
        var clipboardWhileWaiting: String?
        pb.onRestore = { restoredAt.append(clock.t) }
        let paster = Paster(
            pasteboard: pb, postCmdV: { pastedByCommandV.append(pb.string() ?? "<nothing>") },
            schedule: sched.schedule, restoreDelay: 2.0, clock: clock.now,
            sleep: { seconds in
                sleeps.append(seconds)
                clipboardWhileWaiting = pb.string()
                clock.t += seconds
            })
        let reader = PasteboardSelectionReader(
            pasteboard: pb,
            keys: CopyKeys(onPress: { pb.userCopies([[text: Data(Self.selected.utf8)]]) }),
            waitSeconds: 0.25, pollSeconds: 0.125,
            settle: { await paster.settlePendingRestore() },
            sleep: { _ in })
        let states = Box<PipelineState>()
        let pipeline = EditPipeline(
            recorder: FakeRecorder(), stt: FakeStt(text: "make it shorter"),
            backend: { FakeEditBackend(out: Self.shortened) }, modelIsGemma4: { true }, selection: reader,
            paster: paster, config: PipelineConfig(), clock: clock.now, frontmost: { 42 },
            sinks: EditSinks(
                onState: { states.append($0) }, onNotice: { _ in }, onVerdict: { _ in }, onProblem: { _ in },
                onStat: { _ in }, runner: { work in runBlocking(work) }),
            onLog: nil)

        // The edit's hold began before the dictation pasted; its release comes 125 ms after that paste.
        pipeline.keyDown()
        clock.t = 0.5
        try paster.paste("dictated words")
        clock.t = 0.625
        pipeline.keyUp()

        XCTAssertEqual(sleeps.value, [1.875], "the settle waits for the rest of the 2 s restore delay, no less")
        XCTAssertEqual(clipboardWhileWaiting, "dictated words", "the app has had its paste; the clipboard is still scribe's")
        XCTAssertEqual(restoredAt.value.first, 2.5, "the user's clipboard returns at paste time + restore delay")
        XCTAssertEqual(
            pastedByCommandV.value, ["dictated words", Self.shortened],
            "⌘V only ever pasted scribe's own text, never the user's clipboard")
        XCTAssertEqual(states.value, [.recording, .processing, .idle])
        sched.fireAll()
        XCTAssertEqual(pb.items, usersClipboard, "the user's clipboard, not the copied selection, ends up on the pasteboard")
    }
}

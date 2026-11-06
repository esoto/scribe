import Foundation

/// How the edit pipeline reports back. Handed to the pipeline factory so the coordinator owns the hop to the main
/// actor, like `PipelineSinks`.
struct EditSinks {
    let onState: (PipelineState) -> Void
    let onNotice: (String) -> Void
    /// The pill's one-line verdict: the verb after a paste, or why nothing was pasted. Never selection text.
    let onVerdict: (String) -> Void
    /// Why an edit failed ("Edit failed — transcription"), shown as ⚠ where a verdict, rejections included, is ◦.
    let onProblem: (String) -> Void
    let onStat: (EditStat) -> Void
    /// The coordinator's single serial worker, shared with the dictation pipeline: an edit's ⌘C must never run between
    /// a dictation's ⌘V and the restore that follows it.
    let runner: (@escaping () async -> Void) -> Void
}

/// Edit-by-voice: hold ⇧ with the hotkey over a selection and say what to change. The selection is copied at the
/// release, the spoken instruction is matched to one of seven verbs, the active cleanup model rewrites the selection,
/// the deterministic gates check the result, and only an accepted result is pasted over the selection.
///
/// Nothing textual leaves this class except through the fixed phrases of `onVerdict` and `onProblem` and the paste
/// itself: the selection, the instruction and the result never reach a log line, a stat or an error message.
final class EditPipeline {
    static let notAnEditHint = "Not an edit — say shorter, formal, to Spanish…"
    static let noModelHint = "No cleanup model — pick one in Settings › Models"

    /// Gemma 3 needs 10.35 s for a 200-word translation, which dictation's 0.03 s a word (10.5 s) all but spends.
    static let secondsPerWordOverFifty = 0.045

    static func deadline(words: Int, base: Double) -> Double {
        DictationPipeline.cleanupDeadline(words: words, base: base, perWord: secondsPerWordOverFifty)
    }

    private let recorder: RecorderLike
    private var stt: SttEngine
    private let backend: () -> (any CleanupModelBackend)?
    private let modelIsGemma4: () -> Bool
    private let selectionReader: SelectionReader
    private let paster: SelectionReplacing
    private let config: PipelineConfig
    /// Main-only (Settings writes, `keyUp` reads); kept out of `config`, which the runner reads off-main.
    private var holdThreshold: Double
    private let clock: () -> Double
    private let frontmost: () -> pid_t?
    /// Read fresh each edit: a misheard instruction ("shorted") is fixed by the Dictionary like a dictation.
    private let replacementPairs: () -> [ReplacementPair]
    private let sinks: EditSinks
    private let onLog: ((String) -> Void)?

    private(set) var engineName: String

    private var downAt: Double?
    /// Per hold, not per pipeline: queued jobs outlive later key-downs, which would otherwise retarget them.
    private var downTarget: pid_t?
    /// True from a successful key-down until the hold ends; main-only, so the coordinator can read it synchronously.
    private(set) var isArmed = false
    /// A job only touches the glyph while no hold is in progress and no newer job is queued, else its
    /// .processing/.idle would blank the ● of the edit in progress. The lock orders a job's emission against key
    /// events; process() reads this from the runner's thread.
    private let stateLock = NSLock()
    private var holding = false
    private var latestJob = 0
    /// Jobs a key-up enqueued that have not finished; a key-up that finds one ahead of it is queued. Under `stateLock`.
    private var jobsInFlight = 0

    init(
        recorder: RecorderLike,
        stt: SttEngine,
        backend: @escaping () -> (any CleanupModelBackend)?,
        modelIsGemma4: @escaping () -> Bool,
        selection: SelectionReader,
        paster: SelectionReplacing,
        config: PipelineConfig,
        clock: @escaping () -> Double,
        frontmost: @escaping () -> pid_t? = { nil },
        replacementPairs: @escaping () -> [ReplacementPair] = { [] },
        sinks: EditSinks,
        onLog: ((String) -> Void)? = nil
    ) {
        self.recorder = recorder
        self.stt = stt
        self.engineName = stt.name
        self.backend = backend
        self.modelIsGemma4 = modelIsGemma4
        self.selectionReader = selection
        self.paster = paster
        self.config = config
        self.holdThreshold = config.holdThreshold
        self.clock = clock
        self.frontmost = frontmost
        self.replacementPairs = replacementPairs
        self.sinks = sinks
        self.onLog = onLog
    }

    // MARK: - Public API

    func keyDown() {
        do {
            try recorder.arm()
        } catch {
            onLog?("recorder arm failed: \(type(of: error))")
            let notice = UserFacingError.recordingNotice(error: "\(error)")
            sinks.onNotice(notice)
            sinks.onProblem(notice)
            return
        }
        isArmed = true
        downAt = clock()
        downTarget = frontmost()
        stateLock.withLock {
            holding = true
            sinks.onState(.recording)
        }
    }

    func keyUp() {
        guard isArmed else { return }
        isArmed = false
        let pcm = recorder.disarm()
        let held = clock() - (downAt ?? 0.0)
        guard held >= holdThreshold else {
            endHoldIdle()
            return
        }
        let enqueuedAt = clock()
        let job = stateLock.withLock {
            holding = false
            latestJob += 1
            // The job ahead stops touching the glyph once this one is the latest, so without this the ● would stay
            // until it finishes, however long that takes.
            if jobsInFlight > 0 {
                sinks.onState(.processing)
            }
            jobsInFlight += 1
            return latestJob
        }
        let target = downTarget
        sinks.runner { [weak self] in
            guard let self else { return }
            await self.process(pcm, job: job, target: target, enqueuedAt: enqueuedAt)
        }
    }

    /// Hold watchdog: a release the tap never reported must not record until the ring buffer overflows.
    func forceStop(notice: String? = nil) {
        guard isArmed else { return }
        sinks.onNotice(notice ?? "Stopped after \(Int(config.maxHold / 60)) min — release the key")
        keyUp()
    }

    /// System sleep mid-hold: the release may never arrive, and editing on wake into whatever has focus is wrong.
    func cancelHold() {
        guard isArmed else { return }
        isArmed = false
        _ = recorder.disarm()
        endHoldIdle()
    }

    /// A hold that yields no job (discarded tap, cancelled hold) ends here.
    private func endHoldIdle() {
        stateLock.withLock {
            holding = false
            sinks.onState(.idle)
        }
    }

    func setEngine(_ engine: SttEngine, name: String) {
        self.stt = engine
        self.engineName = name
    }

    /// Read at each key release, so a change applies from the next hold.
    func setHoldThreshold(_ seconds: Double) {
        holdThreshold = seconds
    }

    // MARK: - Processing (runs on the injected runner)

    private func process(_ pcm: [Float], job: Int, target: pid_t?, enqueuedAt: Double) async {
        func emit(_ state: PipelineState) {
            stateLock.withLock { if !holding, latestJob == job { sinks.onState(state) } }
        }
        // The line goes out before the final idle: the coordinator keeps it on the pill only if it is already there
        // when the idle arrives. A failure is a problem (⚠); everything else, a rejection included, is a verdict (◦).
        func finish(_ line: String?, asProblem: Bool = false, stat: EditStat? = nil) {
            if let line {
                if asProblem { sinks.onProblem(line) } else { sinks.onVerdict(line) }
            }
            if let stat { sinks.onStat(stat) }
            emit(.idle)
        }
        // Declared first so it runs last: every exit below, the early returns included, frees the slot.
        defer { stateLock.withLock { jobsInFlight -= 1 } }

        let age = clock() - enqueuedAt
        if age > config.queueMaxAge {
            // A ⌘C into whatever has focus this long after the release is worse than dropping the edit.
            let skipped = "Edit skipped — it waited \(Int(age)) s behind the previous one"
            sinks.onNotice(skipped)
            finish(skipped, asProblem: true)
            return
        }
        emit(.processing)

        guard Gates.passesEnergyGate(pcm, threshold: config.energyGate) else {
            // Near-silent capture (likely a missing Microphone grant): there is no instruction to wait for, and no
            // reason to touch the clipboard.
            finish(DictationPipeline.noSpeechHint)
            return
        }

        // The selection first: "nothing selected" must cost no model work, and the ⌘C goes out after the key-up,
        // when ⇧ and the hotkey are no longer physically down. Not under a deadline: a read cut off mid-wait could
        // leave the copy on the clipboard with no one to put the user's back.
        let read: Selection?
        do {
            read = try await selectionReader.read(target: target)
        } catch let guarded as PasteGuardError {
            sinks.onNotice(guarded.notice)
            finish(nil)
            return
        } catch {
            onLog?("edit: selection read failed: \(type(of: error))")
            finish("Edit failed — check log", asProblem: true)
            return
        }
        guard let selection = read else {
            finish("Nothing selected")
            return
        }
        // Every exit from here on has copied: unless a paste follows, the clipboard it displaced goes back.
        func putTheClipboardBack() {
            paster.restoreClipboardAfterCopy(selection.snapshot, copiedChangeCount: selection.copiedChangeCount)
        }

        let t0 = clock()
        let heardRaw: String
        do {
            let engine = stt
            heardRaw = Gates.normalize(try await withDeadline(config.sttTimeout) { try await engine.transcribe(pcm) })
        } catch {
            // The type only: an engine's message is not ours to vouch for.
            onLog?("edit: transcription failed (\(engineName)): \(type(of: error))")
            putTheClipboardBack()
            finish("Edit failed — transcription", asProblem: true)
            return
        }
        let sttMs = Int((clock() - t0) * 1000)
        let heard = TermReplacer.apply(replacementPairs(), to: heardRaw)

        guard let verb = EditVerb.match(heard) else {
            putTheClipboardBack()
            finish(Self.notAnEditHint)
            return
        }
        guard let backend = backend() else {
            putTheClipboardBack()
            finish(Self.noModelHint, asProblem: true)
            return
        }

        let words = selection.text.split(whereSeparator: { $0.isWhitespace }).count
        // The first edit after launch or an idle unload builds its warm prefix inside the call; E5 measures whether
        // that needs a pre-warm.
        let deadline = Self.deadline(words: words, base: config.cleanupTimeout)
        let maxTokens = EditPrompt.maxTokens(verb: verb, inputTokens: selection.text.count / 4)
        let instruction = EditPrompt.instruction(verb: verb, selection: selection.text)
        let t1 = clock()
        let verdict: EditVerdict
        var resultChars = 0
        do {
            // withDeadline also cancels the call when the deadline fires, so Gemma's token loop frees the model.
            let out = try await withDeadline(deadline) {
                try await backend.edit(instruction: instruction, text: selection.text, maxTokens: maxTokens)
            }
            resultChars = out.count
            verdict = EditGates.accept(verb: verb, selection: selection.text, result: out)
        } catch is DeadlineExceeded {
            verdict = .rejected(.timeout)
        } catch {
            onLog?("edit: model call failed: \(type(of: error))")
            putTheClipboardBack()
            finish("Edit failed — check log", asProblem: true)
            return
        }
        let editMs = Int((clock() - t1) * 1000)
        let counts = "stt_ms=\(sttMs) edit_ms=\(editMs) in_chars=\(selection.text.count)"

        switch verdict {
        case .rejected(let why):
            putTheClipboardBack()
            onLog?("edit: engine=\(engineName) verb=\(verb.logName) rejected=\(why.rawValue) \(counts) out_chars=\(resultChars)")
            finish(
                EditGates.pillReason(why, modelIsGemma4: modelIsGemma4()),
                stat: EditStat(verb: verb, sttMs: sttMs, editMs: editMs, accepted: false, rejection: why))
        case .accepted(let text):
            // The pill never claims an edit that was not pasted: a refused paste leaves its notice alone, a failed
            // one adds the ⚠.
            var line: String? = verb.displayName
            var failed = false
            do {
                try paster.replaceSelection(
                    text, target: target, restoring: selection.snapshot, copiedChangeCount: selection.copiedChangeCount)
            } catch let guarded as PasteGuardError {
                // The guard left the edit on the clipboard and the selection is still selected: ⌘V finishes the job.
                sinks.onNotice(guarded.notice)
                line = nil
            } catch {
                let notice = "Edit failed — press ⌘V to paste manually"
                sinks.onNotice(notice)
                line = notice
                failed = true
            }
            onLog?("edit: engine=\(engineName) verb=\(verb.logName) \(counts) out_chars=\(text.count)")
            finish(
                line, asProblem: failed,
                stat: EditStat(verb: verb, sttMs: sttMs, editMs: editMs, accepted: true, rejection: nil))
        }
    }
}

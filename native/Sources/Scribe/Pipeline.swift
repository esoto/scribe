import Foundation

/// Thrown by SttEngine.transcribe; the only error that gets the ⚠ state + save audio + notify.
struct SttError: Error {
    let message: String
}

enum PipelineState {
    case idle, recording, processing, error
}

struct PipelineConfig {
    var holdThreshold: Double = 0.3
    var energyGate: Double = 0.0005
    var minWords: Int = 4
    var cleanupTimeout: Double = 6.0
    var sttTimeout: Double = 20.0
    /// Caps what an experimental denoise can add to a dictation; past it the raw capture is transcribed.
    var enhanceTimeout: Double = 3.0
    /// A queued job older than this is dropped rather than pasted into whatever has focus by then.
    var queueMaxAge: Double = 30.0
    /// The ring buffer silently drops audio past 300 s, so a stuck key is cut off well before that.
    var maxHold: Double = 120.0
    var lengthBand: (Double, Double) = (0.5, 1.3)
    var sampleRate: Double = 16000.0
}

/// Why a cleanup attempt fell back to the raw transcript. The raw values are what scribe.log records.
enum CleanupSkip: String, Error {
    case timeout, error, empty, length, language
}

/// Shown for a few seconds after a dictation pasted the raw transcript, so raw and cleaned stop looking alike.
func pastedRawHint(_ skip: CleanupSkip) -> String {
    switch skip {
    case .timeout: return "Pasted raw — cleanup timed out"
    case .error: return "Pasted raw — cleanup failed"
    case .empty, .length, .language: return "Pasted raw — cleanup output rejected"
    }
}

protocol RecorderLike {
    func arm() throws
    func disarm() -> [Float]
}

/// Test seam over Paster.paste; Paster conforms retroactively below.
/// `target` is the app that had focus when the dictation began; nil when unknown.
protocol Pasting {
    func paste(_ text: String, target: pid_t?) throws
}

extension Paster: Pasting {}

/// Dictation orchestrator: state machine + degradation policy.
final class DictationPipeline {
    /// Shown when a hold that passed the tap threshold captured near-silence.
    static let noSpeechHint = "No speech heard"

    private let recorder: RecorderLike
    private var stt: SttEngine
    private var cleaner: CleanupBackend?
    private(set) var cleanupModelName: String = ""
    private let paster: Pasting
    private let history: History
    private let config: PipelineConfig
    /// Main-only (Settings writes, `keyUp` reads); kept out of `config`, which the runner reads off-main.
    private var holdThreshold: Double
    private let clock: () -> Double
    private let runner: (@escaping () async -> Void) -> Void
    private let frontmost: () -> pid_t?
    private let onState: (PipelineState) -> Void
    private let onNotice: (String) -> Void
    private let onLog: ((String) -> Void)?
    /// Fired only for a successfully cleaned dictation; raw STT is never offered (harvesting relies on LLM casing).
    private let onCleaned: ((String) -> Void)?
    /// Read fresh each dictation; applied deterministically here, not via the cleanup prompt.
    private let replacementPairs: () -> [ReplacementPair]
    private let saveFailedAudio: ([Float]) -> Void
    /// A short verdict on the last dictation for the status row; fires only for degradations, never for the user's own choices.
    private let onHint: (String) -> Void
    /// Fires after a paste that went through, never when the text only reached the clipboard.
    private let onPasted: () -> Void
    /// Runs before STT when `enhanceAudioEnabled`; nil leaves the captured audio untouched.
    private let enhancer: AudioEnhancer?

    private(set) var engineName: String
    var cleanupEnabled: Bool
    var enhanceAudioEnabled: Bool

    private var downAt: Double?
    /// Per hold, not per pipeline: queued jobs outlive later key-downs, which would otherwise retarget them.
    private var downTarget: pid_t?
    private var isArmed = false
    /// A job only touches the glyph while no hold is in progress and no newer job is queued, else its
    /// .processing/.idle would blank the ● of the dictation in progress. A discarded short tap starts a hold
    /// but no job, so it must not orphan the in-flight job's glyph. The lock orders a job's emission against
    /// key events; process() reads this from the runner's thread.
    private let stateLock = NSLock()
    private var holding = false
    private var latestJob = 0

    init(
        recorder: RecorderLike,
        stt: SttEngine,
        cleaner: CleanupBackend?,
        paster: Pasting,
        history: History,
        config: PipelineConfig,
        clock: @escaping () -> Double,
        runner: ((@escaping () async -> Void) -> Void)? = nil,
        frontmost: @escaping () -> pid_t? = { nil },
        onState: @escaping (PipelineState) -> Void,
        onNotice: @escaping (String) -> Void,
        saveFailedAudio: @escaping ([Float]) -> Void,
        cleanupEnabled: Bool = true,
        enhancer: AudioEnhancer? = nil,
        enhanceAudioEnabled: Bool = false,
        onLog: ((String) -> Void)? = nil,
        onCleaned: ((String) -> Void)? = nil,
        replacementPairs: @escaping () -> [ReplacementPair] = { [] },
        onHint: @escaping (String) -> Void = { _ in },
        onPasted: @escaping () -> Void = {}
    ) {
        self.recorder = recorder
        self.stt = stt
        self.engineName = stt.name
        self.cleaner = cleaner
        self.paster = paster
        self.history = history
        self.config = config
        self.holdThreshold = config.holdThreshold
        self.clock = clock
        self.runner = runner ?? DictationPipeline.makeSerialRunner()
        self.frontmost = frontmost
        self.onState = onState
        self.onNotice = onNotice
        self.saveFailedAudio = saveFailedAudio
        self.cleanupEnabled = cleanupEnabled
        self.enhancer = enhancer
        self.enhanceAudioEnabled = enhanceAudioEnabled
        self.onLog = onLog
        self.onCleaned = onCleaned
        self.replacementPairs = replacementPairs
        self.onHint = onHint
        self.onPasted = onPasted
    }

    // MARK: - Public API

    func keyDown() {
        do {
            try recorder.arm()
        } catch {
            onLog?("recorder arm failed: \(error)")
            onNotice(UserFacingError.recordingNotice(error: "\(error)"))
            return
        }
        isArmed = true
        downAt = clock()
        downTarget = frontmost()
        stateLock.withLock {
            holding = true
            onState(.recording)
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
            return latestJob
        }
        let target = downTarget
        runner { [weak self] in
            guard let self else { return }
            await self.process(pcm, job: job, target: target, enqueuedAt: enqueuedAt)
        }
    }

    /// Hold watchdog: a release the tap never reported must not record until the ring buffer overflows.
    func forceStop() {
        guard isArmed else { return }
        onNotice("Stopped after \(Int(config.maxHold / 60)) min — release the key")
        keyUp()
    }

    /// System sleep mid-hold: the release may never arrive, and pasting on wake into whatever has focus is wrong.
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
            onState(.idle)
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

    func setCleaner(_ cleaner: CleanupBackend?, name: String) {
        self.cleaner = cleaner
        self.cleanupModelName = name
    }

    // MARK: - Processing (runs on the injected runner)

    private func process(_ pcm: [Float], job: Int, target: pid_t?, enqueuedAt: Double) async {
        func emit(_ state: PipelineState) {
            stateLock.withLock { if !holding, latestJob == job { onState(state) } }
        }
        let age = clock() - enqueuedAt
        if age > config.queueMaxAge {
            // Pasting a dictation this stale into whatever has focus now is worse than dropping it.
            onNotice("Dictation skipped — it waited \(Int(age)) s behind the previous one")
            emit(.idle)
            return
        }
        emit(.processing)
        var terminal = false   // .error is terminal: no trailing .idle, so the ⚠ stays visible
        defer { if !terminal { emit(.idle) } }

        guard Gates.passesEnergyGate(pcm, threshold: config.energyGate) else {
            // Near-silent capture (likely missing Microphone TCC grant). The hold already passed the tap threshold, so
            // this isn't an accidental tap: say so in the status row, but no notification.
            onHint(DictationPipeline.noSpeechHint)
            return
        }

        let t0 = clock()
        // Enhancement is best-effort: a failed or slow denoise must not cost the dictation,
        // so any error falls back to the raw capture.
        var input = pcm
        var enhanceMs = 0
        var enhanceSkipNote = ""
        if enhanceAudioEnabled, let enhancer {
            do {
                input = try await withDeadline(config.enhanceTimeout) { try await enhancer.enhance(pcm) }
            } catch is DeadlineExceeded {
                enhanceSkipNote = " enhance_skip=timeout"
            } catch {
                onLog?("enhance failed: \(error)")
                enhanceSkipNote = " enhance_skip=error"
            }
            enhanceMs = Int((clock() - t0) * 1000)
        }
        // After enhancement, so stt= is the transcription alone.
        let sttStart = clock()
        func failTranscription(_ notice: String, reason: String) {
            // The status row says "Error — check log", so the log has to say what failed.
            onLog?("stt failed (\(engineName)): \(reason)")
            saveFailedAudio(pcm)
            onNotice(notice)
            terminal = true
            emit(.error)
        }
        let raw: String
        do {
            let engine = stt
            let audio = input
            raw = Gates.normalize(try await withDeadline(config.sttTimeout) { try await engine.transcribe(audio) })
        } catch let sttError as SttError {
            failTranscription(
                UserFacingError.transcriptionNotice(engineMessage: sttError.message), reason: sttError.message)
            return
        } catch is DeadlineExceeded {
            failTranscription(
                "Transcription timed out after \(Int(config.sttTimeout)) s — audio saved",
                reason: "timed out after \(Int(config.sttTimeout)) s")
            return
        } catch {
            // Non-SttError failures have no defined contract here; log, but keep the dictation quiet.
            onLog?("stt failed (\(engineName)): unexpected error: \(error)")
            return
        }

        // STT time includes Parakeet vocab biasing; split it out so stt=/bias= are disjoint.
        let sttTotalMs = Int((clock() - sttStart) * 1000)
        let biasMs = (stt as? ParakeetEngine)?.lastBiasMs ?? 0
        let sttMs = max(0, sttTotalMs - biasMs)

        guard !raw.isEmpty else {
            onNotice("Nothing transcribed")
            return
        }

        // Applied before cleanup (model reads what was said) and after (cleanup may recase it).
        // Unconditional so it also covers too-short, disabled, and gated-out cleanup.
        let pairs = replacementPairs()
        let transcript = TermReplacer.apply(pairs, to: raw)

        var final = transcript
        var cleaned = false
        var cleanupMs = 0
        var skipNote = ""
        var cleanupSkip: CleanupSkip?
        if let cleaner,
            Gates.shouldClean(transcript, enabled: cleanupEnabled, minWords: config.minWords)
        {
            let cleanStart = clock()
            switch await tryClean(transcript, cleaner: cleaner) {
            case .success(let out):
                final = TermReplacer.apply(pairs, to: out)
                cleaned = true
            case .failure(let skip):
                // The reason token only: the backend's error text could echo the dictated text.
                skipNote = " cleanup_skip=\(skip.rawValue)"
                cleanupSkip = skip
            }
            cleanupMs = Int((clock() - cleanStart) * 1000)
        }
        onLog?("dictation: engine=\(engineName) cleanupModel=\(cleanupModelName) stt=\(sttMs)ms bias=\(biasMs)ms enhance=\(enhanceMs)ms cleanup=\(cleanupMs)ms cleaned=\(cleaned) chars=\(final.count)\(enhanceSkipNote)\(skipNote)")

        if cleaned {
            onCleaned?(final)
        }

        do {
            try paster.paste(final, target: target)
            onPasted()
            // Only a degradation gets a hint: disabled or too-short cleanup is the user's choice.
            if let cleanupSkip { onHint(pastedRawHint(cleanupSkip)) }
        } catch let guarded as PasteGuardError {
            onNotice(guarded.notice)
        } catch {
            onNotice("Paste failed — press ⌘V to paste manually")
        }

        let durationMs = Int((clock() - t0) * 1000)
        history.append(DictationRecord(
            raw: raw,
            final: final,
            engine: engineName,
            cleaned: cleaned,
            at: Date(),
            durationMs: durationMs
        ))
    }

    /// The failure case is any gate/error that means "use raw", with the reason it was hit.
    private func tryClean(_ raw: String, cleaner: CleanupBackend) async -> Result<String, CleanupSkip> {
        let out: String
        do {
            // withDeadline also cancels the call when the deadline fires, so Gemma's token loop frees the model.
            out = Gates.normalize(try await withDeadline(config.cleanupTimeout) { try await cleaner.clean(raw) })
        } catch {
            return .failure(error is DeadlineExceeded ? .timeout : .error)
        }
        guard !out.isEmpty else { return .failure(.empty) }
        guard Gates.lengthOk(raw: raw, cleaned: out, band: config.lengthBand) else { return .failure(.length) }
        guard Gates.languageConsistent(raw: raw, cleaned: out) else { return .failure(.language) }
        return .success(out)
    }

    // MARK: - Default runner

    /// One serial worker per pipeline: FIFO AsyncStream drained by a single Task, so dictations never overlap.
    private static func makeSerialRunner() -> (@escaping () async -> Void) -> Void {
        let worker = SerialWorker()
        return { work in worker.enqueue(work) }
    }
}

/// @unchecked Sendable: the only mutable state (AsyncStream.Continuation) is safe for concurrent use.
private final class SerialWorker: @unchecked Sendable {
    private let continuation: AsyncStream<() async -> Void>.Continuation
    private let drainTask: Task<Void, Never>

    init() {
        let (stream, continuation) = AsyncStream<() async -> Void>.makeStream()
        self.continuation = continuation
        self.drainTask = Task {
            for await work in stream {
                await work()
            }
        }
    }

    deinit {
        drainTask.cancel()
        continuation.finish()
    }

    func enqueue(_ work: @escaping () async -> Void) {
        continuation.yield(work)
    }
}

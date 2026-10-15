import Foundation

/// Thrown by SttEngine.transcribe; the only error that gets flash ERROR + save audio + notify.
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
    var lengthBand: (Double, Double) = (0.5, 1.3)
    var sampleRate: Double = 16000.0
}

protocol RecorderLike {
    func arm() throws
    func disarm() -> [Float]
}

/// Test seam over Paster.paste; Paster conforms retroactively below.
protocol Pasting {
    func paste(_ text: String) throws
}

extension Paster: Pasting {}

/// Internal cleanup-race signal; always mapped to "use raw" by tryClean.
private struct CleanupTimeoutError: Error {}

/// Dictation orchestrator: state machine + degradation policy.
final class DictationPipeline {
    private let recorder: RecorderLike
    private var stt: SttEngine
    private var cleaner: CleanupBackend?
    private(set) var cleanupModelName: String = ""
    private let paster: Pasting
    private let history: History
    private let config: PipelineConfig
    private let clock: () -> Double
    private let runner: (@escaping () async -> Void) -> Void
    private let onState: (PipelineState) -> Void
    private let onNotice: (String) -> Void
    private let onLog: ((String) -> Void)?
    /// Fired only for a successfully cleaned dictation; raw STT is never offered (harvesting relies on LLM casing).
    private let onCleaned: ((String) -> Void)?
    /// Read fresh each dictation; applied deterministically here, not via the cleanup prompt.
    private let replacementPairs: () -> [ReplacementPair]
    private let saveFailedAudio: ([Float]) -> Void
    /// Runs before STT when `enhanceAudioEnabled`; nil leaves the captured audio untouched.
    private let enhancer: AudioEnhancer?

    private(set) var engineName: String
    var cleanupEnabled: Bool
    var enhanceAudioEnabled: Bool

    private var downAt: Double?
    private var isArmed = false

    init(
        recorder: RecorderLike,
        stt: SttEngine,
        cleaner: CleanupBackend?,
        paster: Pasting,
        history: History,
        config: PipelineConfig,
        clock: @escaping () -> Double,
        runner: ((@escaping () async -> Void) -> Void)? = nil,
        onState: @escaping (PipelineState) -> Void,
        onNotice: @escaping (String) -> Void,
        saveFailedAudio: @escaping ([Float]) -> Void,
        cleanupEnabled: Bool = true,
        enhancer: AudioEnhancer? = nil,
        enhanceAudioEnabled: Bool = false,
        onLog: ((String) -> Void)? = nil,
        onCleaned: ((String) -> Void)? = nil,
        replacementPairs: @escaping () -> [ReplacementPair] = { [] }
    ) {
        self.recorder = recorder
        self.stt = stt
        self.engineName = stt.name
        self.cleaner = cleaner
        self.paster = paster
        self.history = history
        self.config = config
        self.clock = clock
        self.runner = runner ?? DictationPipeline.makeSerialRunner()
        self.onState = onState
        self.onNotice = onNotice
        self.saveFailedAudio = saveFailedAudio
        self.cleanupEnabled = cleanupEnabled
        self.enhancer = enhancer
        self.enhanceAudioEnabled = enhanceAudioEnabled
        self.onLog = onLog
        self.onCleaned = onCleaned
        self.replacementPairs = replacementPairs
    }

    // MARK: - Public API

    func keyDown() {
        do {
            try recorder.arm()
        } catch {
            onNotice("Failed to start recording: \(error)")
            return
        }
        isArmed = true
        downAt = clock()
        onState(.recording)
    }

    func keyUp() {
        guard isArmed else { return }
        isArmed = false
        let pcm = recorder.disarm()
        let held = clock() - (downAt ?? 0.0)
        guard held >= config.holdThreshold else {
            onState(.idle)
            return
        }
        runner { [weak self] in
            guard let self else { return }
            await self.process(pcm)
        }
    }

    func setEngine(_ engine: SttEngine, name: String) {
        self.stt = engine
        self.engineName = name
    }

    func setCleaner(_ cleaner: CleanupBackend?, name: String) {
        self.cleaner = cleaner
        self.cleanupModelName = name
    }

    // MARK: - Processing (runs on the injected runner)

    private func process(_ pcm: [Float]) async {
        onState(.processing)
        defer { onState(.idle) }

        guard Gates.passesEnergyGate(pcm, threshold: config.energyGate) else {
            // Near-silent capture (likely missing Microphone TCC grant); no notice, expected from accidental taps.
            return
        }

        let t0 = clock()
        let sttStart = t0
        // Enhancement is best-effort: a failed or slow denoise must not cost the dictation,
        // so any error falls back to the raw capture.
        var input = pcm
        var enhanceMs = 0
        if enhanceAudioEnabled, let enhancer {
            let enhanceStart = clock()
            input = (try? await enhancer.enhance(pcm)) ?? pcm
            enhanceMs = Int((clock() - enhanceStart) * 1000)
        }
        let raw: String
        do {
            raw = Gates.normalize(try await stt.transcribe(input))
        } catch let sttError as SttError {
            saveFailedAudio(pcm)
            onNotice("Transcription failed: \(sttError.message)")
            onState(.error)
            return
        } catch {
            // Non-SttError failures have no defined contract here.
            return
        }

        // STT time includes Parakeet vocab biasing; split it out so stt=/bias= are disjoint.
        let sttTotalMs = Int((clock() - sttStart) * 1000)
        let biasMs = (stt as? ParakeetEngine)?.lastBiasMs ?? 0
        let sttMs = max(0, sttTotalMs - biasMs - enhanceMs)

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
        if let cleaner,
            Gates.shouldClean(transcript, enabled: cleanupEnabled, minWords: config.minWords)
        {
            let cleanStart = clock()
            if let out = await tryClean(transcript, cleaner: cleaner) {
                final = TermReplacer.apply(pairs, to: out)
                cleaned = true
            }
            cleanupMs = Int((clock() - cleanStart) * 1000)
        }
        onLog?("dictation: engine=\(engineName) cleanupModel=\(cleanupModelName) stt=\(sttMs)ms bias=\(biasMs)ms enhance=\(enhanceMs)ms cleanup=\(cleanupMs)ms cleaned=\(cleaned) chars=\(final.count)")

        if cleaned {
            onCleaned?(final)
        }

        do {
            try paster.paste(final)
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

    /// Returns nil for any gate/error that means "use raw".
    private func tryClean(_ raw: String, cleaner: CleanupBackend) async -> String? {
        let out: String
        do {
            out = Gates.normalize(try await cleanWithTimeout(raw: raw, cleaner: cleaner, timeout: config.cleanupTimeout))
        } catch {
            return nil
        }
        guard !out.isEmpty, Gates.lengthOk(raw: raw, cleaned: out, band: config.lengthBand) else {
            return nil
        }
        guard Gates.languageConsistent(raw: raw, cleaned: out) else {
            return nil
        }
        return out
    }

    private func cleanWithTimeout(raw: String, cleaner: CleanupBackend, timeout: Double) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await cleaner.clean(raw)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                throw CleanupTimeoutError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CleanupTimeoutError()
            }
            return result
        }
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

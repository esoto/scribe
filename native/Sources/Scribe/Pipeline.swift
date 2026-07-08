import Foundation

/// Error thrown by `SttEngine.transcribe` on failure — the only error type
/// that gets the "flash ERROR + save audio + notify" treatment in `_process`,
/// mirroring `scribe.stt.base.SttError` in the Python app.
struct SttError: Error {
    let message: String
}

enum PipelineState {
    case idle, recording, processing, error
}

/// Mirrors the subset of `scribe.config.Config` the pipeline reads.
/// Passed as a plain struct so the pipeline never touches UserDefaults.
struct PipelineConfig {
    var holdThreshold: Double = 0.3
    var energyGate: Double = 0.0005
    var minWords: Int = 4
    var cleanupTimeout: Double = 6.0
    var lengthBand: (Double, Double) = (0.5, 1.3)
    var sampleRate: Double = 16000.0
}

/// Testable seam over recorder arm/disarm (the real implementation wraps
/// AVAudioEngine capture in a later task).
protocol RecorderLike {
    func arm() throws
    func disarm() -> [Float]
}

/// Testable seam over `Paster.paste`. `Paster` (PasteCore.swift) is a
/// concrete `final class` with no protocol of its own; rather than modify
/// that file, this protocol structurally matches its `paste(_:)` method and
/// `Paster` is given a zero-code retroactive conformance below so production
/// code can pass a real `Paster` while tests pass a `FakePaster`.
protocol Pasting {
    func paste(_ text: String) throws
}

extension Paster: Pasting {}

/// Internal signal for the cleanup race — never surfaced to callers, always
/// mapped to "use raw" by `tryClean`.
private struct CleanupTimeoutError: Error {}

/// Dictation orchestrator: state machine + degradation policy.
///
/// Ported 1:1 from `scribe.pipeline.Pipeline` (src/scribe/pipeline.py). Every
/// collaborator is injected so the whole failure matrix in spec §5 is
/// unit-testable without hardware or models. See PipelineTests.swift for the
/// full port of tests/test_pipeline.py.
final class DictationPipeline {
    private let recorder: RecorderLike
    private var stt: SttEngine
    private let cleaner: CleanupBackend?
    private let paster: Pasting
    private let history: History
    private let config: PipelineConfig
    private let clock: () -> Double
    private let runner: (@escaping () async -> Void) -> Void
    private let onState: (PipelineState) -> Void
    private let onNotice: (String) -> Void
    /// Optional diagnostic sink for per-dictation stage timings. Never carries
    /// transcript text — only durations, engine name, and stage labels.
    private let onLog: ((String) -> Void)?
    private let saveFailedAudio: ([Float]) -> Void

    private(set) var engineName: String
    var cleanupEnabled: Bool

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
        onLog: ((String) -> Void)? = nil
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
        self.onLog = onLog
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

    // MARK: - Processing (runs on the injected runner)

    private func process(_ pcm: [Float]) async {
        onState(.processing)
        defer { onState(.idle) }

        guard Gates.passesEnergyGate(pcm, threshold: config.energyGate) else {
            // All-zero/near-silent capture discarded — usually means the
            // Microphone TCC grant is missing. No notice: this is expected
            // noise from accidental taps, not a user-facing failure.
            return
        }

        let t0 = clock()
        let sttStart = t0
        let raw: String
        do {
            raw = Gates.normalize(try await stt.transcribe(pcm))
        } catch let sttError as SttError {
            saveFailedAudio(pcm)
            onNotice("Transcription failed: \(sttError.message)")
            onState(.error)
            return
        } catch {
            // Non-SttError transcription failures have no defined contract
            // (mirrors Python, where only `except SttError` is caught here
            // and anything else propagates to the worker's catch-all log).
            return
        }

        let sttMs = Int((clock() - sttStart) * 1000)

        guard !raw.isEmpty else {
            onNotice("Nothing transcribed")
            return
        }

        var final = raw
        var cleaned = false
        var cleanupMs = 0
        if let cleaner, Gates.shouldClean(raw, enabled: cleanupEnabled, minWords: config.minWords) {
            let cleanStart = clock()
            if let out = await tryClean(raw, cleaner: cleaner) {
                final = out
                cleaned = true
            }
            cleanupMs = Int((clock() - cleanStart) * 1000)
        }
        onLog?("dictation: engine=\(engineName) stt=\(sttMs)ms cleanup=\(cleanupMs)ms cleaned=\(cleaned) chars=\(final.count)")

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

    /// Returns the cleaned text on success, or nil if any gate/error means
    /// "use raw" (cleanup error, timeout, empty output, length gate,
    /// language-flip gate) — same fallback set as Python's `_try_clean`.
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

    /// Races `cleaner.clean` against a timeout using structured concurrency —
    /// the Swift-native equivalent of Python's `future.result(timeout=...)`.
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

    /// One dedicated serial worker per pipeline instance: an `AsyncStream`
    /// buffers enqueued work in FIFO order, drained by a single `Task` so two
    /// dictations back-to-back never run concurrently (mirrors Python's
    /// single-thread `_drain` loop over a `queue.Queue`).
    private static func makeSerialRunner() -> (@escaping () async -> Void) -> Void {
        let worker = SerialWorker()
        return { work in worker.enqueue(work) }
    }
}

/// FIFO async work queue drained by exactly one `Task`. `@unchecked Sendable`
/// because the only mutable state (`AsyncStream.Continuation`) is itself
/// safe for concurrent use from multiple callers.
private final class SerialWorker: @unchecked Sendable {
    private let continuation: AsyncStream<() async -> Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<() async -> Void>.makeStream()
        self.continuation = continuation
        Task {
            for await work in stream {
                await work()
            }
        }
    }

    func enqueue(_ work: @escaping () async -> Void) {
        continuation.yield(work)
    }
}

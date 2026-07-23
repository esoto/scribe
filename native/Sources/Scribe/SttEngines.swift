import FluidAudio
import Foundation
import WhisperKit

/// Idle-unloadable lazy holder for a model of type `M` — the Swift-native
/// equivalent of Python's `ThreadBound*` model wrappers. An `actor`, but
/// actor isolation on its own does NOT prevent double-loading: `get()`
/// suspends at `try await factory()`, and the actor can interleave a second
/// `get()` call in that gap, so two concurrent callers can both observe
/// `model == nil` and both start a load. To keep "load-once" true, the first
/// caller publishes an in-flight `Task` that later callers await instead of
/// starting their own factory call — see `get()`.
actor LazyModel<M> {
    private let label: String
    private let factory: () async throws -> M
    private var model: M?
    private var inFlight: Task<M, Error>?

    init(label: String, factory: @escaping () async throws -> M) {
        self.label = label
        self.factory = factory
    }

    /// Loads the model via `factory` on first call (logging load seconds)
    /// and returns the cached instance on subsequent calls. Concurrent
    /// callers that arrive while a load is already underway await the same
    /// in-flight `Task` instead of triggering their own `factory()` call, so
    /// the model is constructed at most once even under a slow first load.
    func get() async throws -> M {
        if let model {
            return model
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { [factory, label] () throws -> M in
            let t0 = Date()
            let loaded = try await factory()
            let elapsed = Date().timeIntervalSince(t0)
            print("[LazyModel] \(label) loaded in \(String(format: "%.2f", elapsed))s")
            return loaded
        }
        inFlight = task
        defer { inFlight = nil }
        let loaded = try await task.value
        model = loaded
        return loaded
    }

    /// Drops the cached reference so the next `get()` reloads from scratch.
    /// Deliberately leaves any in-flight load alone: if a load started
    /// before `unload()` is still running, it will finish and repopulate
    /// `model` afterward rather than being cancelled. That's an acceptable
    /// (and simplest-to-reason-about) outcome — `unload()` is a hint to
    /// drop idle memory, not a hard guarantee that no load is in progress.
    func unload() {
        model = nil
    }

    var isLoaded: Bool {
        model != nil
    }

    /// Best-effort warm-up: loads the model and swallows any failure (a
    /// failed preload just means the next real `get()` will retry and
    /// surface the error to its caller instead).
    func preload() async {
        _ = try? await get()
    }
}

/// Adds the idle-unload lifecycle hooks the app's memory manager (Task 13)
/// needs on top of `SttEngine.transcribe`.
protocol UnloadableEngine: SttEngine {
    func unload() async
    func preload() async
    var isLoaded: Bool { get async }
}

/// FluidAudio Parakeet v3 STT engine.
///
/// NOTE: this is compile-only for Task 10 — it is exercised against real
/// audio fixtures by `ScribeModelTests` in Task 15, since that's the only
/// test target linked against the FluidAudio/WhisperKit packages.
final class ParakeetEngine: UnloadableEngine {
    let name = "parakeet"

    private let lazyModel: LazyModel<AsrManager>
    /// Auxiliary CTC keyword-spotter model for vocabulary biasing — a
    /// separate download from the TDT model. Its factory throws on load
    /// failure (offline, etc.) so `LazyModel` does NOT cache the failure and
    /// the next dictation retries; `applyBiasing` catches the throw and
    /// transcribes unbiased. Never a fatal error.
    private let lazyCtc: LazyModel<CtcModels>

    /// Bias vocabulary + the rescorer built from it, guarded by `biasLock`.
    /// The cached trio is keyed on `cachedTerms` (the exact vocabulary it was
    /// built from), NOT a dirty flag: a rebuild is triggered whenever the
    /// requested terms differ from what's cached. Keying on identity rather
    /// than a boolean is what makes a failed rebuild retry (the cache still
    /// holds the OLD terms, so the next call still mismatches) and defeats the
    /// lost-update race where a vocab change lands mid-dictation.
    private let biasLock = NSLock()
    private var biasVocabulary: [BiasTerm] = []
    private var cachedTerms: [BiasTerm]?
    private var cachedRescorer: VocabularyRescorer?
    private var cachedContext: CustomVocabularyContext?
    private var cachedSpotter: CtcKeywordSpotter?

    /// Records why the last dictation's biasing did or didn't fire. Exposed
    /// for the model-backed tests: the graceful do/catch means a broken
    /// rescorer would otherwise pass a no-regression test silently, so the
    /// smoke test asserts this is NOT `.failed`.
    enum BiasOutcome: Equatable { case disabled, noCtcModel, noTimings, unmodified, applied, failed }
    private(set) var lastBiasOutcomeForTesting: BiasOutcome = .disabled

    init() {
        lazyModel = LazyModel(label: "parakeet") {
            // Downloaded into the app-managed store, not FluidAudio's
            // default Application Support/FluidAudio cache.
            let models = try await AsrModels.downloadAndLoad(
                to: ModelStore.parakeetDirectory, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        lazyCtc = LazyModel(label: "parakeet-ctc") {
            // Throws on failure (NOT try?) so LazyModel doesn't cache a failed
            // load as a permanent success-of-nil — the next dictation retries.
            try await CtcModels.downloadAndLoad(
                to: ModelStore.ctcDirectory, variant: .ctc110m)
        }
    }

    /// Publishes a new bias vocabulary. Takes effect on the next
    /// `transcribe`; load-free and callable before any model is resident.
    func setBiasVocabulary(_ terms: [BiasTerm]) {
        biasLock.withLock { biasVocabulary = terms }
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        do {
            let manager = try await lazyModel.get()
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(pcm, decoderState: &state)
            let biased = await applyBiasing(to: result, pcm: pcm)
            return biased.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as SttError {
            throw error
        } catch {
            throw SttError(message: "\(error)")
        }
    }

    /// Rescores `result.text` toward the bias vocabulary using the auxiliary
    /// CTC model. Every failure path returns the plain transcription — biasing
    /// can only ever improve output, never break a dictation. `TermReplacer`
    /// still runs downstream regardless.
    private func applyBiasing(to result: ASRResult, pcm: [Float]) async -> String {
        let terms = biasLock.withLock { biasVocabulary }
        guard !terms.isEmpty else { lastBiasOutcomeForTesting = .disabled; return result.text }

        // A load failure throws; catch it here so biasing degrades to plain
        // text without the failure being cached (the next dictation retries).
        guard let ctc = try? await lazyCtc.get() else {
            lastBiasOutcomeForTesting = .noCtcModel
            return result.text
        }

        do {
            let (context, spotter, rescorer) = try await rescorer(for: terms, ctc: ctc)
            guard !context.terms.isEmpty else {
                lastBiasOutcomeForTesting = .disabled
                return result.text
            }

            let spot = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: pcm, customVocabulary: context, minScore: nil)
            guard let timings = result.tokenTimings, !timings.isEmpty, !spot.logProbs.isEmpty
            else { lastBiasOutcomeForTesting = .noTimings; return result.text }

            let cfg = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count)
            let out = rescorer.ctcTokenRescore(
                transcript: result.text,
                tokenTimings: timings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: cfg.cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: cfg.minSimilarity)
            lastBiasOutcomeForTesting = out.wasModified ? .applied : .unmodified
            return out.wasModified ? out.text : result.text
        } catch {
            print("[ParakeetEngine] vocabulary biasing skipped: \(error)")
            lastBiasOutcomeForTesting = .failed
            return result.text
        }
    }

    /// Returns the cached rescorer trio, rebuilding it when the vocabulary
    /// changed. Tokenization + rescorer construction happen once per vocab
    /// change, not per dictation.
    private func rescorer(for terms: [BiasTerm], ctc: CtcModels) async throws
        -> (CustomVocabularyContext, CtcKeywordSpotter, VocabularyRescorer)
    {
        // Reuse only when the cache was built from exactly these terms.
        let cached = biasLock.withLock {
            () -> (CustomVocabularyContext, CtcKeywordSpotter, VocabularyRescorer)? in
            guard cachedTerms == terms, let ctx = cachedContext, let sp = cachedSpotter,
                let rs = cachedRescorer
            else { return nil }
            return (ctx, sp, rs)
        }
        if let cached { return cached }

        // The bundle (incl. tokenizer.json) lives where we downloaded it —
        // ModelStore.ctcDirectory — NOT FluidAudio's default cache that
        // CtcModels.defaultCacheDirectory(for:) points at.
        let modelDir = ModelStore.ctcDirectory
        let tokenizer = try await CtcTokenizer.load(from: modelDir)
        let vocabTerms = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text, weight: 10.0, aliases: term.aliases, ctcTokenIds: ids)
        }
        let context = CustomVocabularyContext(terms: vocabTerms)
        let spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context, config: .default, ctcModelDirectory: modelDir)

        // Record the terms only on success, so a thrown rebuild leaves the
        // old (mismatching) cachedTerms in place and the next call retries.
        biasLock.withLock {
            cachedTerms = terms
            cachedContext = context
            cachedSpotter = spotter
            cachedRescorer = rescorer
        }
        return (context, spotter, rescorer)
    }

    func unload() async {
        await lazyModel.unload()
        await lazyCtc.unload()
        biasLock.withLock {
            cachedTerms = nil
            cachedRescorer = nil
            cachedContext = nil
            cachedSpotter = nil
        }
    }
    func preload() async {
        await lazyModel.preload()
        // Warm the CTC model in the background too, but ONLY when there's a
        // vocabulary to bias with — otherwise a biasing-off user would pay an
        // unnecessary download/load. Fire-and-forget so a slow/absent CTC
        // never delays TDT readiness; LazyModel coalesces this with the
        // get() inside applyBiasing, so the first biased dictation no longer
        // stalls on the load.
        if !biasLock.withLock({ biasVocabulary.isEmpty }) {
            Task { await lazyCtc.preload() }
        }
    }
    // CTC is auxiliary — the engine is "loaded" iff the TDT model is.
    var isLoaded: Bool { get async { await lazyModel.isLoaded } }
}

extension NSLock {
    @inline(__always) fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

/// WhisperKit (large-v3-turbo) STT engine.
///
/// NOTE: this is compile-only for Task 10 — it is exercised against real
/// audio fixtures by `ScribeModelTests` in Task 15, since that's the only
/// test target linked against the FluidAudio/WhisperKit packages.
final class WhisperEngine: UnloadableEngine {
    let name = "whisper"

    private let lazyModel: LazyModel<WhisperKit>

    init() {
        lazyModel = LazyModel(label: "whisper") {
            // downloadBase roots WhisperKit's models/argmaxinc/… tree in
            // the app-managed store instead of ~/Documents/huggingface.
            try await WhisperKit(
                WhisperKitConfig(
                    model: "openai_whisper-large-v3-v20240930_turbo",
                    downloadBase: ModelStore.whisperDirectory))
        }
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        do {
            let pipe = try await lazyModel.get()
            let opts = DecodingOptions(
                task: .transcribe,
                language: nil,
                temperature: 0.0,
                usePrefillPrompt: false,
                detectLanguage: true,
                skipSpecialTokens: true,
                chunkingStrategy: .vad
            )
            let results = try await pipe.transcribe(audioArray: pcm, decodeOptions: opts)
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as SttError {
            throw error
        } catch {
            throw SttError(message: "\(error)")
        }
    }

    func unload() async { await lazyModel.unload() }
    func preload() async { await lazyModel.preload() }
    var isLoaded: Bool { get async { await lazyModel.isLoaded } }
}

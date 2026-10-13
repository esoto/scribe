import FluidAudio
import Foundation
import WhisperKit

/// Lazy, idle-unloadable model holder. Actor isolation alone doesn't prevent double-loading across the factory await, so the first caller publishes an in-flight Task that later callers await.
actor LazyModel<M> {
    private let label: String
    private let factory: () async throws -> M
    private var model: M?
    private var inFlight: Task<M, Error>?

    init(label: String, factory: @escaping () async throws -> M) {
        self.label = label
        self.factory = factory
    }

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

    /// Does not cancel an in-flight load; it may repopulate the model afterward.
    func unload() {
        model = nil
    }

    var isLoaded: Bool {
        model != nil
    }

    /// Best-effort warm-up; swallows failure so the next real get() retries.
    func preload() async {
        _ = try? await get()
    }
}

protocol UnloadableEngine: SttEngine {
    func unload() async
    func preload() async
    var isLoaded: Bool { get async }
}

/// FluidAudio Parakeet v3 STT engine.
final class ParakeetEngine: UnloadableEngine {
    let name = "parakeet"

    private let lazyModel: LazyModel<AsrManager>
    /// Auxiliary CTC keyword-spotter (separate download). Its factory throws on failure so LazyModel doesn't cache it; applyBiasing catches and transcribes unbiased.
    private let lazyCtc: LazyModel<CtcModels>

    /// Bias vocab + rescorer, guarded by `biasLock`. Keyed on `cachedTerms` (not a dirty flag) so a failed rebuild retries and a mid-dictation vocab change isn't lost.
    private let biasLock = NSLock()
    private var biasVocabulary: [BiasTerm] = []
    private var cachedTerms: [BiasTerm]?
    private var cachedRescorer: VocabularyRescorer?
    private var cachedContext: CustomVocabularyContext?
    private var cachedSpotter: CtcKeywordSpotter?

    /// Why the last dictation's biasing did or didn't fire; tests assert it is not `.failed`.
    enum BiasOutcome: Equatable { case disabled, noCtcModel, noTimings, unmodified, applied, failed }
    private(set) var lastBiasOutcomeForTesting: BiasOutcome = .disabled

    /// Milliseconds the last transcribe spent biasing; written and read only on the serial dictation path.
    private(set) var lastBiasMs: Int = 0

    /// Similarity floor for accepting a rescoring replacement. The library default (0.50-0.60) replaces ordinary words with loose vocab matches; 0.75 trades recall for precision.
    static let biasMinSimilarity: Float = 0.75

    init() {
        lazyModel = LazyModel(label: "parakeet") {
            // Downloaded into the app-managed store, not FluidAudio's default cache.
            let models = try await AsrModels.downloadAndLoad(
                to: ModelStore.parakeetDirectory, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        lazyCtc = LazyModel(label: "parakeet-ctc") {
            // Throws (not try?) so LazyModel doesn't cache a failed load; the next dictation retries.
            try await CtcModels.downloadAndLoad(
                to: ModelStore.ctcDirectory, variant: .ctc110m)
        }
    }

    func setBiasVocabulary(_ terms: [BiasTerm]) {
        biasLock.withLock { biasVocabulary = terms }
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        do {
            let manager = try await lazyModel.get()
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(pcm, decoderState: &state)
            let biasStart = Date()
            let biased = await applyBiasing(to: result, pcm: pcm)
            lastBiasMs = Int(Date().timeIntervalSince(biasStart) * 1000)
            return biased.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as SttError {
            throw error
        } catch {
            throw SttError(message: "\(error)")
        }
    }

    /// Every failure path returns the plain transcription; biasing never breaks a dictation.
    private func applyBiasing(to result: ASRResult, pcm: [Float]) async -> String {
        let terms = biasLock.withLock { biasVocabulary }
        guard !terms.isEmpty else { lastBiasOutcomeForTesting = .disabled; return result.text }

        // A load failure throws; degrade to plain text without caching it.
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
                minSimilarity: Self.biasMinSimilarity)
            lastBiasOutcomeForTesting = out.wasModified ? .applied : .unmodified
            return out.wasModified ? out.text : result.text
        } catch {
            print("[ParakeetEngine] vocabulary biasing skipped: \(error)")
            lastBiasOutcomeForTesting = .failed
            return result.text
        }
    }

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

        // The bundle lives in ModelStore.ctcDirectory, not FluidAudio's default cache.
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

        // Record terms only on success so a thrown rebuild retries next call.
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
        // Warm CTC in the background only when there is a vocabulary; fire-and-forget so it never delays TDT readiness.
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
final class WhisperEngine: UnloadableEngine {
    let name = "whisper"

    private let lazyModel: LazyModel<WhisperKit>

    init() {
        lazyModel = LazyModel(label: "whisper") {
            // downloadBase roots models in the app-managed store, not ~/Documents/huggingface.
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

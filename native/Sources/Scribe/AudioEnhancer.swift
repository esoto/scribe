import FluidAudio
import Foundation

/// Optional speech enhancement applied to captured audio before STT.
protocol AudioEnhancer {
    func enhance(_ pcm: [Float]) async throws -> [Float]
}

/// What the app drives besides `enhance`: loading and freeing the model, like `UnloadableEngine` for STT.
protocol UnloadableEnhancer: AudioEnhancer {
    func preload() async
    func unload() async
    var isLoaded: Bool { get async }
}

/// The slice of `LocalVqeManager` the enhancer uses; the seam that keeps the tests off CoreML.
protocol VqeProcessing: Sendable {
    func process(mic: [Float]) async throws -> [Float]
}

extension LocalVqeManager: VqeProcessing {}

/// LocalVQE (acoustic echo cancellation + noise suppression + dereverberation), already
/// bundled with FluidAudio — no extra dependency, ~19 MB model downloaded on first use.
///
/// EXPERIMENTAL, and OFF by default. On synthetic pink noise it raised Parakeet's WER on
/// 8 of 12 clip/SNR combinations, including turning Spanish speech into English gibberish
/// at 0 dB SNR. Parakeet is trained on noise-injected audio and handles additive noise on
/// its own; enhancement hands it artifacts it never saw. Enable only to try it against
/// real-world noise, where LocalVQE's training data is a better match.
///
/// The model is only ever loaded by `preload()`. A cold start downloads and compiles for far longer than a
/// dictation lasts, so `enhance` passes the audio through untouched until a preload has finished.
final class LocalVQEEnhancer: UnloadableEnhancer, @unchecked Sendable {
    /// Builds the processor. `progress` takes the download fraction (0…1) on any thread.
    typealias Factory = (@escaping @Sendable (Double) -> Void) async throws -> any VqeProcessing

    /// `main` of FluidInference/localvqe-coreml on 2026-10-18. The model transforms every dictation while the
    /// feature is on, so a swapped upstream repo must not become a silent model swap. Bump deliberately.
    static let pinnedRevision = "4205430781c240397073d6f7bf676fb4c732fc12"

    private let lazyModel: LazyModel<any VqeProcessing>
    private let onLog: (@Sendable (String) -> Void)?
    private let coldNoticeLock = NSLock()
    private var coldNoticeLogged = false

    /// `onDownloadProgress` reports the download (0…1) on any thread; 1 also means "done or gave up".
    init(
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil,
        onLog: (@Sendable (String) -> Void)? = nil,
        factory: @escaping Factory = LocalVQEEnhancer.loadFromStore
    ) {
        self.onLog = onLog
        lazyModel = LazyModel(label: "enhance", onLog: onLog) {
            defer { onDownloadProgress?(1) }
            return try await factory { onDownloadProgress?($0) }
        }
    }

    /// Hand-off to `ModelHub`: it appends the repo's folder name to the directory it is given, so the store's
    /// base directory yields `ModelStore.localVqeDirectory`. FluidAudio's own default would be a second model
    /// home outside the store.
    static func loadFromStore(progress: @escaping @Sendable (Double) -> Void) async throws -> any VqeProcessing {
        let config = LocalVqeConfig.default
        let file = ModelNames.LocalVQE.modelFile(variant: config.variant, chunk: config.chunk)
        let models = try await ModelHub.loadModels(
            .localVqe,
            modelNames: [file],
            directory: ModelStore.baseDirectory,
            computeUnits: config.computeUnits,
            variant: ModelNames.LocalVQE.variantKey(variant: config.variant, chunk: config.chunk),
            progressHandler: { progress($0.fractionCompleted) })
        guard let model = models[file] else {
            throw LocalVqeError.modelLoadingFailed("\(file) missing after download")
        }
        return LocalVqeManager(config: config, model: model)
    }

    /// Writes FluidAudio's process-wide revision override, which is unsynchronized: call it once at launch,
    /// before anything downloads.
    static func pinModelRevision() {
        ModelRegistry.revisionOverrides[Repo.localVqe.remotePath] = pinnedRevision
    }

    func enhance(_ pcm: [Float]) async throws -> [Float] {
        // peek, not get: get() would start the download inside the dictation if an unload landed after a check.
        guard let vqe = await lazyModel.peek() else {
            logColdOnce()
            return pcm
        }
        // No far-end reference: LocalVQE still denoises and dereverberates, passing silence for it.
        return try await vqe.process(mic: pcm)
    }

    /// Best-effort; a failed load is logged and not cached, so the next preload retries it.
    func preload() async {
        await lazyModel.preload()
    }

    func unload() async {
        await lazyModel.unload()
        coldNoticeLock.withLock { coldNoticeLogged = false }
    }

    var isLoaded: Bool { get async { await lazyModel.isLoaded } }

    /// Once per cold stretch, or every dictation would repeat it.
    private func logColdOnce() {
        let first = coldNoticeLock.withLock { () -> Bool in
            defer { coldNoticeLogged = true }
            return !coldNoticeLogged
        }
        if first { onLog?("enhance: model not loaded, raw audio used") }
    }
}

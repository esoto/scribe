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
    }

    func transcribe(_ pcm: [Float]) async throws -> String {
        do {
            let manager = try await lazyModel.get()
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(pcm, decoderState: &state)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

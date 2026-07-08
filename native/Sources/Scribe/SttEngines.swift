import FluidAudio
import Foundation
import WhisperKit

/// Idle-unloadable lazy holder for a model of type `M` — the Swift-native
/// equivalent of Python's `ThreadBound*` model wrappers. An `actor` so
/// concurrent `get()` callers during a slow first load are serialized rather
/// than racing to construct the model twice.
actor LazyModel<M> {
    private let label: String
    private let factory: () async throws -> M
    private var model: M?

    init(label: String, factory: @escaping () async throws -> M) {
        self.label = label
        self.factory = factory
    }

    /// Loads the model via `factory` on first call (logging load seconds)
    /// and returns the cached instance on subsequent calls.
    func get() async throws -> M {
        if let model {
            return model
        }
        let t0 = Date()
        let loaded = try await factory()
        let elapsed = Date().timeIntervalSince(t0)
        print("[LazyModel] \(label) loaded in \(String(format: "%.2f", elapsed))s")
        model = loaded
        return loaded
    }

    /// Drops the cached reference so the next `get()` reloads from scratch.
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
            let models = try await AsrModels.downloadAndLoad(version: .v3)
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
            try await WhisperKit(WhisperKitConfig(model: "openai_whisper-large-v3-v20240930_turbo"))
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

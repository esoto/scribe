import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Error thrown by `CleanupBackend.clean` on failure — matches the pattern
/// of `SttError` in Pipeline.swift.
struct CleanupError: Error {
    let message: String
}

/// Adds the idle-unload lifecycle hooks the app's memory manager (Task 13)
/// needs on top of `CleanupBackend.clean`.
protocol UnloadableCleaner: CleanupBackend {
    func unload() async
    func preload() async
    var isLoaded: Bool { get async }
}

/// MLX Gemma 3 4B QAT cleanup backend via `#huggingFaceLoadModelContainer`.
///
/// Each call to `clean(_:)` creates a fresh `ChatSession` with the few-shot
/// examples to maintain statelessness and predictability across multiple
/// cleanup requests.
final class GemmaBackend: UnloadableCleaner {
    private let lazyModel: LazyModel<ModelContainer>

    init() {
        lazyModel = LazyModel(label: "gemma-cleanup") {
            try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(id: "mlx-community/gemma-3-4b-it-qat-4bit")
            )
        }
    }

    /// Cleans a raw dictation transcript using the Gemma 3 4B model with
    /// few-shot examples. Wraps errors into `CleanupError`.
    func clean(_ text: String) async throws -> String {
        do {
            let container = try await lazyModel.get()

            // Build few-shot history from CleanupPrompt.fewShots, mapping each
            // (input, output) pair to [.user(input), .assistant(output)] messages.
            // The user turn must go through CleanupPrompt.wrap(), same as the
            // real query below — Python's build_messages() (src/scribe/cleanup/base.py)
            // wraps every few-shot AND real user turn in <transcript> tags. Leaving
            // the few-shots unwrapped rendered a prompt where only the final query
            // carried the <transcript> markup the examples never demonstrated,
            // which measurably weakened the "never translate" instruction (2/10
            // golden cases regressed, both English inputs translated to Spanish;
            // fixed in Task 15).
            let history = CleanupPrompt.fewShots.flatMap { input, output in
                [
                    Chat.Message.user(CleanupPrompt.wrap(input)),
                    Chat.Message.assistant(output)
                ]
            }

            let session = ChatSession(
                container,
                instructions: CleanupPrompt.systemPrompt,
                history: history,
                generateParameters: GenerateParameters(
                    maxTokens: CleanupPrompt.maxTokens(inputTokens: text.count / 4),
                    temperature: 0.0
                )
            )

            let cleaned = try await session.respond(to: CleanupPrompt.wrap(text))
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as CleanupError {
            throw error
        } catch {
            throw CleanupError(message: "\(error)")
        }
    }

    func unload() async { await lazyModel.unload() }
    func preload() async { await lazyModel.preload() }
    var isLoaded: Bool { get async { await lazyModel.isLoaded } }
}

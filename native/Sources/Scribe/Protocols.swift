import Foundation

/// Speech-to-text engine adapter (Parakeet/FluidAudio, whisper, etc.).
protocol SttEngine {
    var name: String { get }
    func transcribe(_ pcm: [Float]) async throws -> String
}

/// LLM-backed cleanup backend (e.g. Gemma via MLX).
protocol CleanupBackend {
    func clean(_ text: String) async throws -> String
}

/// Testable seam over NSPasteboard.
protocol PasteboardLike {
    func get() -> String?
    func set(_ s: String)
    func changeCount() -> Int
}

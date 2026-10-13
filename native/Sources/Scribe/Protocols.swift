import Foundation

/// Implementations must wrap every `transcribe(_:)` failure in `SttError`; other error types are silently swallowed.
protocol SttEngine {
    var name: String { get }
    func transcribe(_ pcm: [Float]) async throws -> String
}

protocol CleanupBackend {
    func clean(_ text: String) async throws -> String
}

protocol PasteboardLike {
    func get() -> String?
    func set(_ s: String)
    func changeCount() -> Int
}

import Foundation

/// Implementations must wrap every `transcribe(_:)` failure in `SttError`; other error types are silently swallowed.
protocol SttEngine {
    var name: String { get }
    func transcribe(_ pcm: [Float]) async throws -> String
}

protocol CleanupBackend {
    func clean(_ text: String) async throws -> String
}

/// One pasteboard item: UTI → bytes.
typealias PasteboardItemData = [String: Data]

protocol PasteboardLike {
    /// Every item with every type, or nil when the pasteboard is empty.
    func snapshot() -> [PasteboardItemData]?
    func restore(_ items: [PasteboardItemData])
    /// Puts `s` on the pasteboard flagged transient + auto-generated (nspasteboard.org), so history apps skip it.
    func setTransient(_ s: String)
    func changeCount() -> Int
}

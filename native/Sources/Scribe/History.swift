import Foundation

/// A single completed dictation, held only in memory (privacy: never persisted).
struct DictationRecord {
    let raw: String
    let final: String
    let engine: String
    let cleaned: Bool
    let at: Date
    let durationMs: Int
}

/// Bounded, thread-safe in-memory dictation history (privacy: never persisted).
final class History {
    private let maxLen: Int
    private var storage: [DictationRecord] = []
    private let lock = NSLock()

    init(maxLen: Int) {
        self.maxLen = maxLen
    }

    func append(_ r: DictationRecord) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(r)
        if storage.count > maxLen {
            storage.removeFirst(storage.count - maxLen)
        }
    }

    /// Newest first.
    func items() -> [DictationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.reversed())
    }
}

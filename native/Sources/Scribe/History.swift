import Foundation

/// A single completed dictation, held only in memory (privacy: never persisted).
struct DictationRecord: Identifiable {
    // Defaulted let, so it is excluded from the memberwise init.
    let id = UUID()
    let raw: String
    let final: String
    let engine: String
    let cleaned: Bool
    let at: Date
    let durationMs: Int
}

/// Bounded, thread-safe in-memory dictation history (privacy: never persisted).
final class History {
    private var maxLen: Int
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

    /// Shrinking drops the oldest records at once; growing keeps everything already stored.
    func setMaxLen(_ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        maxLen = max(1, n)
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

import Foundation

/// Error thrown when paste delivery fails.
struct PasteError: Error {
    let message: String
}

/// Restores the prior clipboard only if its changeCount is unchanged since the paste.
final class Paster {
    private let pasteboard: PasteboardLike
    private let postCmdV: () throws -> Void
    private let schedule: (Double, @escaping () -> Void) -> Void
    private var restoreDelay: Double
    /// The user's clipboard and the changeCount of our last set. While the clipboard still shows our own
    /// paste, a new dictation must not snapshot it in place of the user's content.
    private var pending: (items: [PasteboardItemData], setCount: Int)?
    // paste() runs on the pipeline worker, restore() on main.
    private let lock = NSLock()

    init(
        pasteboard: PasteboardLike,
        postCmdV: @escaping () throws -> Void,
        schedule: @escaping (Double, @escaping () -> Void) -> Void,
        restoreDelay: Double
    ) {
        self.pasteboard = pasteboard
        self.postCmdV = postCmdV
        self.schedule = schedule
        self.restoreDelay = restoreDelay
    }

    /// Settings change at runtime; the next paste schedules its restore with the new delay.
    func setRestoreDelay(_ seconds: Double) {
        lock.withLock { restoreDelay = seconds }
    }

    /// `target` is GuardedPaster's concern; the default keeps direct callers unchanged.
    func paste(_ text: String, target: pid_t? = nil) throws {
        let (saved, setCount, delay) = lock.withLock {
            let saved: [PasteboardItemData]?
            if let pending, pasteboard.changeCount() == pending.setCount {
                saved = pending.items
            } else {
                saved = pasteboard.snapshot()
            }
            pasteboard.setTransient(text)
            let setCount = pasteboard.changeCount()
            pending = saved.map { ($0, setCount) }
            return (saved, setCount, restoreDelay)
        }

        do {
            try postCmdV()
        } catch {
            throw PasteError(message: String(describing: error))
        }

        if let saved {
            schedule(delay) { [weak self] in
                self?.restore(saved: saved, setCount: setCount)
            }
        }
    }

    /// For when ⌘V can't be sent. The user pastes by hand, so there is no restore to wipe the text.
    func copyOnly(_ text: String) {
        lock.withLock {
            pending = nil
            pasteboard.setTransient(text)
        }
    }

    private func restore(saved: [PasteboardItemData], setCount: Int) {
        lock.withLock {
            // Also frees a snapshot (up to 32 MiB) when the user copied meanwhile.
            if pending?.setCount == setCount { pending = nil }
            guard pasteboard.changeCount() == setCount else { return }
            pasteboard.restore(saved)
        }
    }
}

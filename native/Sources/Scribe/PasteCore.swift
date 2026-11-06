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
    private let clock: () -> Double
    private let sleep: (Double) async -> Void
    private var restoreDelay: Double
    /// The user's clipboard, the changeCount of our last set, and when the restore that paste scheduled is due (on
    /// `clock`). While the clipboard still shows our own paste, a new dictation must not snapshot it in place of the
    /// user's content, and an edit must not copy before the app has had its paste.
    private var pending: (items: [PasteboardItemData], setCount: Int, restoreAt: Double)?
    // paste() runs on the pipeline worker, restore() on main.
    private let lock = NSLock()

    init(
        pasteboard: PasteboardLike,
        postCmdV: @escaping () throws -> Void,
        schedule: @escaping (Double, @escaping () -> Void) -> Void,
        restoreDelay: Double,
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1e9)) }
    ) {
        self.pasteboard = pasteboard
        self.postCmdV = postCmdV
        self.schedule = schedule
        self.restoreDelay = restoreDelay
        self.clock = clock
        self.sleep = sleep
    }

    /// Settings change at runtime; the next paste schedules its restore with the new delay.
    func setRestoreDelay(_ seconds: Double) {
        lock.withLock { restoreDelay = seconds }
    }

    /// `target` is GuardedPaster's concern; the default keeps direct callers unchanged.
    func paste(_ text: String, target: pid_t? = nil) throws {
        try paste(text, target: target, saved: nil)
    }

    /// Pastes over a selection that a ⌘C just read. `snapshot` is the clipboard from before that ⌘C: snapshotting
    /// now would save the copied selection and put it back after the edit. nil means the clipboard was empty, so
    /// it is cleared again after the paste — never "snapshot now", which is exactly that mistake.
    /// `copiedChangeCount` is the count the ⌘C left. If the clipboard has moved since, the user copied something
    /// during the model call: that copy is the clipboard to keep, so the pending-or-snapshot rule applies instead.
    func replaceSelection(
        _ text: String, target: pid_t? = nil, restoring snapshot: [PasteboardItemData]?, copiedChangeCount: Int
    ) throws {
        try paste(text, target: target, saved: (snapshot ?? [], copiedChangeCount))
    }

    private func paste(
        _ text: String, target: pid_t?, saved external: (items: [PasteboardItemData], copiedChangeCount: Int)?
    ) throws {
        let (saved, setCount, delay) = lock.withLock {
            let saved: [PasteboardItemData]?
            if let external, pasteboard.changeCount() == external.copiedChangeCount {
                saved = external.items
            } else if let pending, pasteboard.changeCount() == pending.setCount {
                saved = pending.items
            } else {
                saved = pasteboard.snapshot()
            }
            pasteboard.setTransient(text)
            let setCount = pasteboard.changeCount()
            let delay = restoreDelay
            pending = saved.map { ($0, setCount, clock() + delay) }
            return (saved, setCount, delay)
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

    /// Puts the user's clipboard back now when it still shows our own paste. The selection reader runs this before
    /// its ⌘C: otherwise it would snapshot our transient text as the user's clipboard, and the scheduled restore
    /// could fire during the copy wait and hand the user's old text to the edit as the selection.
    func restorePendingNow() {
        lock.withLock {
            guard let current = pending else { return }
            pending = nil
            guard pasteboard.changeCount() == current.setCount else { return }
            pasteboard.restore(current.items)
        }
    }

    /// Waits until the restore a recent paste scheduled is due, then runs it. The selection reader awaits this before
    /// its ⌘C: restoring sooner could land before the app has read the pasteboard for ⌘V, and the app would paste the
    /// user's clipboard instead of the dictation. Returns at once when no paste is pending or its delay has passed.
    func settlePendingRestore() async {
        let wait = lock.withLock { pending.map { max(0, $0.restoreAt - clock()) } } ?? 0
        if wait > 0 { await sleep(wait) }
        restorePendingNow()
    }

    /// An edit that ends without a paste (nothing to do, rejected, failed): puts back the clipboard the reader's ⌘C
    /// displaced, an empty one when `snapshot` is nil. A clipboard that moved since the copy is the user's own copy
    /// during the model call, and stays.
    func restoreClipboardAfterCopy(_ snapshot: [PasteboardItemData]?, copiedChangeCount: Int) {
        lock.withLock {
            guard pasteboard.changeCount() == copiedChangeCount else { return }
            pasteboard.restore(snapshot ?? [])
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

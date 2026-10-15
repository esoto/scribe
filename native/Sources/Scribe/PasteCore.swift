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
    private let restoreDelay: Double
    /// The user's clipboard and the changeCount of our last set. While the clipboard still shows our own
    /// paste, a new dictation must not snapshot it in place of the user's content.
    private var pending: (items: [PasteboardItemData], setCount: Int)?

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

    func paste(_ text: String) throws {
        let saved: [PasteboardItemData]?
        if let pending, pasteboard.changeCount() == pending.setCount {
            saved = pending.items
        } else {
            saved = pasteboard.snapshot()
        }
        pasteboard.setTransient(text)
        let setCount = pasteboard.changeCount()
        pending = saved.map { ($0, setCount) }

        do {
            try postCmdV()
        } catch {
            throw PasteError(message: String(describing: error))
        }

        if let saved {
            schedule(restoreDelay) { [weak self] in
                self?.restore(saved: saved, setCount: setCount)
            }
        }
    }

    private func restore(saved: [PasteboardItemData], setCount: Int) {
        guard pasteboard.changeCount() == setCount else { return }
        pasteboard.restore(saved)
        pending = nil
    }
}

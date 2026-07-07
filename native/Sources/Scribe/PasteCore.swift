import Foundation

/// Error thrown when paste delivery fails.
struct PasteError: Error {
    let message: String
}

/// Clipboard paste with safe restore.
///
/// The universal dictation-app mechanism (clipboard + synthetic ⌘V) with mitigations:
/// - Configurable restore delay (user has time to paste into the target app)
/// - Change-count check (skip restore if user copied something else meanwhile)
final class Paster {
    private let pasteboard: PasteboardLike
    private let postCmdV: () throws -> Void
    private let schedule: (Double, @escaping () -> Void) -> Void
    private let restoreDelay: Double

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

    /// Paste text to clipboard and post synthetic ⌘V.
    ///
    /// - Saves current clipboard state
    /// - Sets new text to clipboard
    /// - Posts synthetic ⌘V (postCmdV)
    /// - If post fails, throws PasteError (text stays on clipboard, no restore scheduled)
    /// - If post succeeds and saved clipboard was not nil, schedules restore with delay
    /// - Restore only happens if changeCount hasn't changed (user didn't copy meanwhile)
    ///
    /// - Parameter text: The text to paste
    /// - Throws: PasteError if postCmdV throws
    func paste(_ text: String) throws {
        let saved = pasteboard.get()
        pasteboard.set(text)
        let setCount = pasteboard.changeCount()

        do {
            try postCmdV()
        } catch {
            throw PasteError(message: String(describing: error))
        }

        if saved != nil {
            schedule(restoreDelay) { [weak self] in
                self?.restore(saved: saved!, setCount: setCount)
            }
        }
    }

    private func restore(saved: String, setCount: Int) {
        if pasteboard.changeCount() == setCount {
            pasteboard.set(saved)
        }
    }
}

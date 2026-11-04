import Foundation

/// The text the user has selected in the app in front, and the clipboard as it was before scribe looked.
struct Selection: Equatable {
    let text: String
    /// The user's clipboard before the ⌘C, so the final paste restores it rather than the copied selection.
    let snapshot: [PasteboardItemData]?
}

protocol SelectionReader {
    /// nil when nothing was selected (the clipboard did not change, or changed to nothing).
    func read(target: pid_t?) async throws -> Selection?
}

/// Reads the selection with a transient ⌘C. Works wherever copy works, including Electron and web apps; the
/// Accessibility reader behind the same protocol is the stated goal. The copy is made by the source app, so it
/// carries no transient marker — the README says a clipboard manager may record it.
final class PasteboardSelectionReader: SelectionReader {
    private let pasteboard: PasteboardLike
    private let keys: KeyPressing
    private let waitSeconds: Double
    private let pollSeconds: Double
    private let sleep: (Double) async -> Void

    init(
        pasteboard: PasteboardLike, keys: KeyPressing, waitSeconds: Double = 0.3, pollSeconds: Double = 0.02,
        sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.waitSeconds = waitSeconds
        self.pollSeconds = pollSeconds
        self.sleep = sleep
    }

    func read(target: pid_t?) async throws -> Selection? {
        let snapshot = pasteboard.snapshot()
        let before = pasteboard.changeCount()
        try keys.press(.commandC, target: target)
        // The copy lands asynchronously; the change count is the only signal that it did.
        var waited = 0.0
        while pasteboard.changeCount() == before, waited < waitSeconds {
            await sleep(pollSeconds)
            waited += pollSeconds
        }
        guard pasteboard.changeCount() != before else { return nil }
        guard let text = pasteboard.string()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            if let snapshot { pasteboard.restore(snapshot) }
            return nil
        }
        return Selection(text: text, snapshot: snapshot)
    }
}

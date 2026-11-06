import Foundation

/// The text the user has selected in the app in front, and the clipboard as it was before scribe looked.
struct Selection: Equatable {
    let text: String
    /// The user's clipboard before the ⌘C, so the final paste restores it rather than the copied selection.
    /// nil when the clipboard was empty, or held only non-text data above the snapshot's 32 MiB cap (above it
    /// `MacPasteboard.snapshot` keeps plain text only). The paste then clears the clipboard instead of refilling it.
    let snapshot: [PasteboardItemData]?
    /// The change count once the copy landed. While the clipboard still shows it, `snapshot` is the clipboard to
    /// put back; once it moves, the user copied something else and that copy is the one to keep.
    let copiedChangeCount: Int
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
    private let settle: () async -> Void
    private let sleep: (Double) async -> Void

    /// `settle` is awaited first in `read`, before the snapshot: scribe's own recent paste (and the restore it has
    /// pending) must be out of the way, or the snapshot would be scribe's text rather than the user's clipboard.
    /// It may wait out a paste that is still being consumed, so it is async. It has no default: a reader left
    /// unwired would snapshot scribe's own paste, and that must not compile.
    init(
        pasteboard: PasteboardLike, keys: KeyPressing, waitSeconds: Double = 0.3, pollSeconds: Double = 0.02,
        settle: @escaping () async -> Void,
        sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.waitSeconds = waitSeconds
        self.pollSeconds = pollSeconds
        self.settle = settle
        self.sleep = sleep
    }

    func read(target: pid_t?) async throws -> Selection? {
        await settle()
        let snapshot = pasteboard.snapshot()
        let before = pasteboard.changeCount()
        try keys.press(.commandC, target: target)
        // The copy lands asynchronously; the change count is the only signal that it did.
        var waited = 0.0
        while pasteboard.changeCount() == before, waited < waitSeconds {
            await sleep(pollSeconds)
            waited += pollSeconds
        }
        let copiedChangeCount = pasteboard.changeCount()
        guard copiedChangeCount != before else { return nil }
        guard let text = pasteboard.string()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            // An empty snapshot clears: whatever the app copied (an image, say) must not outlive an edit that never was.
            pasteboard.restore(snapshot ?? [])
            return nil
        }
        return Selection(text: text, snapshot: snapshot, copiedChangeCount: copiedChangeCount)
    }
}

import AppKit
import Foundation

/// The guard refused to post ⌘V; `notice` already tells the user the text is on the clipboard.
struct PasteGuardError: Error {
    let notice: String
}

/// A paster that can also leave text on the clipboard without pasting it.
protocol PasteDelivering: Pasting {
    func copyOnly(_ text: String)
}

extension Paster: PasteDelivering {}

/// Posts ⌘V only when it would reach the app the user was dictating into.
/// Without Accessibility the event is dropped silently, and after a focus change it would land in the wrong app.
final class GuardedPaster: Pasting {
    private let inner: PasteDelivering
    private let accessibilityGranted: () -> Bool
    private let currentFrontmost: () -> pid_t?

    init(
        inner: PasteDelivering,
        accessibilityGranted: @escaping () -> Bool,
        currentFrontmost: @escaping () -> pid_t?
    ) {
        self.inner = inner
        self.accessibilityGranted = accessibilityGranted
        self.currentFrontmost = currentFrontmost
    }

    func paste(_ text: String, target: pid_t?) throws {
        guard accessibilityGranted() else {
            inner.copyOnly(text)
            throw PasteGuardError(notice: "Accessibility is off — text copied, press ⌘V")
        }
        // No key-down pid means nothing to compare against, so no guard.
        if let target, target != currentFrontmost() {
            inner.copyOnly(text)
            throw PasteGuardError(notice: "Focus changed — text copied, press ⌘V")
        }
        try inner.paste(text, target: target)
    }
}

/// Safe from any thread: reads directly on main, hops otherwise.
func frontmostPID() -> pid_t? {
    let read = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
}

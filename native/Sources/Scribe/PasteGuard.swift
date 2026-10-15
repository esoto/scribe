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
    private let expectedFrontmost: () -> pid_t?
    private let currentFrontmost: () -> pid_t?

    init(
        inner: PasteDelivering,
        accessibilityGranted: @escaping () -> Bool,
        expectedFrontmost: @escaping () -> pid_t?,
        currentFrontmost: @escaping () -> pid_t?
    ) {
        self.inner = inner
        self.accessibilityGranted = accessibilityGranted
        self.expectedFrontmost = expectedFrontmost
        self.currentFrontmost = currentFrontmost
    }

    func paste(_ text: String) throws {
        guard accessibilityGranted() else {
            inner.copyOnly(text)
            throw PasteGuardError(notice: "Accessibility is off — text copied, press ⌘V")
        }
        // No key-down pid means nothing to compare against, so no guard.
        if let expected = expectedFrontmost(), expected != currentFrontmost() {
            inner.copyOnly(text)
            throw PasteGuardError(notice: "Focus changed — text copied, press ⌘V")
        }
        try inner.paste(text)
    }
}

/// The app that had focus at key-down: written on main by the event tap, read on the pipeline worker at paste time.
final class PasteTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?

    func set(_ pid: pid_t?) {
        lock.withLock { self.pid = pid }
    }

    func get() -> pid_t? {
        lock.withLock { pid }
    }
}

/// Safe from any thread: reads directly on main, hops otherwise.
func frontmostPID() -> pid_t? {
    let read = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
}

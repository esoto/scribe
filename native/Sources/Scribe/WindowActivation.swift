import AppKit

/// LSUIElement apps have no Dock or ⌘Tab presence. While any scribe window is open the app runs as a regular app
/// so the window can be found again; counting keeps a second window from dropping the policy when the first closes.
@MainActor
final class WindowActivation {
    static let shared = WindowActivation(apply: { NSApp.setActivationPolicy($0) })

    private let apply: (NSApplication.ActivationPolicy) -> Void
    private(set) var openWindows = 0

    init(apply: @escaping (NSApplication.ActivationPolicy) -> Void) {
        self.apply = apply
    }

    func windowAppeared() {
        openWindows += 1
        if openWindows == 1 { apply(.regular) }
    }

    func windowDisappeared() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { apply(.accessory) }
    }
}

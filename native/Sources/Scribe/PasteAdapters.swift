import AppKit
import CoreGraphics
import ServiceManagement

/// Error thrown when enabling/disabling the login item fails.
struct LoginItemError: Error {
    let message: String
}

/// `NSPasteboard.general` adapter — the real seam behind `PasteboardLike`.
///
/// Excluded from unit test coverage — it talks to the shared system
/// pasteboard, which would leak into (or be clobbered by) whatever's
/// actually on the clipboard when tests run. `Paster`, the pure logic that
/// consumes `PasteboardLike` (PasteCore.swift), is fully unit-tested
/// against an in-memory fake in PasteCoreTests.swift.
///
/// Ported from `scribe.paste.MacPasteboard` (src/scribe/paste.py).
final class MacPasteboard: PasteboardLike {
    private let pasteboard = NSPasteboard.general

    func get() -> String? {
        pasteboard.string(forType: .string)
    }

    func set(_ s: String) {
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
    }

    func changeCount() -> Int {
        pasteboard.changeCount
    }
}

/// Posts a synthetic ⌘V keystroke (virtual key code 9) to the system HID
/// event tap — the paste half of the clipboard-and-synthetic-keystroke
/// mechanism `Paster` (PasteCore.swift) drives.
///
/// Excluded from unit test coverage — posting real synthetic key events
/// requires the Accessibility grant and affects whatever app is frontmost,
/// which is neither safe nor possible under `xcodebuild test`. `Paster`,
/// the pure logic that calls this via an injected closure, is unit-tested
/// with a fake `postCmdV` closure in PasteCoreTests.swift.
///
/// Ported from `scribe.paste.post_cmd_v` (src/scribe/paste.py).
func postCmdV() throws {
    guard
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
    else {
        throw PasteError(message: "could not create synthetic \u{2318}V key event")
    }

    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand

    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

/// Schedules `fn` to run on the main queue after `delaySeconds` — the real
/// adapter behind `Paster`'s injected `schedule` closure (used for the
/// clipboard-restore delay).
///
/// Excluded from unit test coverage — it's a thin wrapper over
/// `DispatchQueue.main.asyncAfter` with nothing but scheduling behavior;
/// `Paster`'s use of its `schedule` closure is unit-tested with a
/// synchronous fake scheduler in PasteCoreTests.swift.
///
/// Ported from `scribe.paste.timer_schedule` (src/scribe/paste.py).
func timerSchedule(_ delaySeconds: Double, _ fn: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: fn)
}

/// Plays a named system/bundle sound (e.g. "Pop", "Basso") for state-change
/// feedback (recording start, error).
///
/// Excluded from unit test coverage — `NSSound` playback is a fire-and-
/// forget side effect with no observable return value to assert on; the
/// `AppSettings.sounds` toggle that gates whether this gets called is
/// itself unit-tested in AppSettingsTests.swift.
///
/// Ported from `scribe.app._play_sound` (src/scribe/app.py).
enum Sounds {
    static func play(_ name: String) {
        NSSound(named: name)?.play()
    }
}

/// "Start scribe at login" toggle via the modern `SMAppService` API (macOS
/// 13+; this app targets macOS 15+ per project.yml).
///
/// Excluded from unit test coverage — `SMAppService.mainApp` operates on
/// the real login-items registration for the running app bundle; there is
/// no fake seam, and mutating it under `xcodebuild test` would leave the
/// test runner's login items polluted. Verify manually via the app (System
/// Settings > General > Login Items should reflect the toggle).
enum LoginItem {
    static func enable() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw LoginItemError(message: "could not register login item: \(error)")
        }
    }

    static func disable() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw LoginItemError(message: "could not unregister login item: \(error)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

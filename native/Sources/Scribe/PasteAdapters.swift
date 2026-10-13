import AppKit
import CoreGraphics
import ServiceManagement

struct LoginItemError: Error {
    let message: String
}

/// `NSPasteboard.general` adapter. Untested: it would clobber the real clipboard.
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

/// Posts a synthetic ⌘V. Untested: needs Accessibility and would hit the frontmost app.
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

func timerSchedule(_ delaySeconds: Double, _ fn: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds, execute: fn)
}

enum Sounds {
    static func play(_ name: String) {
        NSSound(named: name)?.play()
    }
}

/// `SMAppService` login item. Untested: no fake seam, and it would pollute the test runner's login items.
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

import CoreGraphics
import Foundation

struct HotkeyError: Error {
    let message: String
}

/// Session-level, listen-only `CGEventTap` feeding `KeyStateMachine`. Untested: needs Input Monitoring.
final class HotkeyMonitor {
    private let machine: KeyStateMachine
    private let keycode: Int
    private let onDown: () -> Void
    private let onUp: () -> Void

    /// Fires only for modifier events, so logging it can never capture typed text.
    var onModifierEvent: ((String) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(key: HotKey, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.machine = KeyStateMachine(key: key)
        self.keycode = key.keycode
        self.onDown = onDown
        self.onUp = onUp
    }

    deinit {
        // The C callback holds an unretained self; skipping teardown crashes on the next keystroke.
        teardown()
    }

    /// Throws if tap creation fails or the tap comes back disabled. Call from main, like `reinstall()`.
    func install() throws {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard
            let newTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { proxy, type, event, refcon in
                    HotkeyMonitor.handleEvent(proxy: proxy, type: type, event: event, refcon: refcon)
                },
                userInfo: selfPtr
            )
        else {
            throw HotkeyError(message: "event tap denied — grant Input Monitoring in System Settings")
        }

        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        // macOS 26 can create the tap without the grant and leave it disabled; check tapIsEnabled.
        guard CGEvent.tapIsEnabled(tap: newTap) else {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFMachPortInvalidate(newTap)
            throw HotkeyError(
                message: "event tap created but disabled — Input Monitoring grant is not "
                    + "reaching this process. Grant Input Monitoring to scribe in System "
                    + "Settings, then retry (onboarding calls reinstall() after the grant)."
            )
        }

        tap = newTap
        runLoopSource = source
    }

    /// Replaces the tap; onboarding uses this to activate the hotkey right after the grant.
    func reinstall() throws {
        teardown()
        try install()
    }

    private func teardown() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    /// C callback trampoline; recovers `self` from the unretained `userInfo` pointer.
    private static func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        refcon: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

        // Re-enable after timeouts or secure input, or the hotkey dies for the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // A release during the gap is gone; end the hold rather than record until the next tap. A key still
            // physically down keeps its hold, or the dictation is cut short and the real release is ignored.
            if !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(monitor.keycode)), monitor.machine.reset() {
                monitor.onUp()
            }
            return nil
        }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let action = monitor.machine.handle(
            eventType: Int(type.rawValue), keycode: keycode, flags: event.flags.rawValue
        )
        if type == .flagsChanged {
            monitor.onModifierEvent?(
                "flagsChanged keycode=\(keycode) flags=0x\(String(event.flags.rawValue, radix: 16)) -> \(action.map(String.init(describing:)) ?? "nil")"
            )
        }
        switch action {
        case .down: monitor.onDown()
        case .up: monitor.onUp()
        case nil: break
        }

        return Unmanaged.passUnretained(event)
    }
}

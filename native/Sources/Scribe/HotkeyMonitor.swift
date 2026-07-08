import CoreGraphics
import Foundation

/// Error thrown when the CGEventTap cannot be installed or enabled.
struct HotkeyError: Error {
    let message: String
}

/// Hold-to-talk key listener: wires the pure `KeyStateMachine` to a
/// session-level, listen-only `CGEventTap`.
///
/// Excluded from unit test coverage — a real event tap needs the Input
/// Monitoring TCC grant and a running `CFRunLoop`, neither available under
/// `xcodebuild test`. `KeyStateMachine`, the pure logic this drives, is
/// fully unit-tested in KeyStateMachineTests.swift. Verify manually via the
/// app (and the onboarding live-activation path exercised through
/// `reinstall()`).
///
/// Ported from `scribe.hotkey.HotkeyListener` (src/scribe/hotkey.py).
final class HotkeyMonitor {
    private let machine: KeyStateMachine
    private let onDown: () -> Void
    private let onUp: () -> Void

    /// Diagnostic hook, fired ONLY for flagsChanged (modifier) events — never
    /// for regular keystrokes, so wiring it to a log file cannot capture
    /// typed text. Called on the tap's run-loop thread.
    var onModifierEvent: ((String) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(key: HotKey, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.machine = KeyStateMachine(key: key)
        self.onDown = onDown
        self.onUp = onUp
    }

    deinit {
        // The C callback holds an unretained pointer to self. Without this
        // teardown, deallocation while the tap is live leaves a dangling refcon
        // that crashes on the next keystroke.
        teardown()
    }

    /// Installs the session-level, listen-only event tap over
    /// flagsChanged/keyDown/keyUp and adds its run-loop source to the
    /// current run loop's common modes.
    ///
    /// Throws `HotkeyError` if tap creation is denied outright, or — the
    /// hard-won macOS 26 lesson carried over from the Python reference —
    /// if creation silently succeeds but the tap is left disabled because
    /// the Input Monitoring grant isn't reaching this process. We check
    /// `CGEvent.tapIsEnabled` after `tapEnable` rather than trusting a
    /// non-nil tap; see `scribe.hotkey.HotkeyListener.install`.
    ///
    /// Must be called on the thread whose run loop pumps the tap — call
    /// install() and reinstall() from the same thread (main).
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

        // On macOS 26, tap creation can SUCCEED without the Input Monitoring
        // grant and the tap is just silently left disabled — check, don't
        // trust the non-nil result above.
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

    /// Tears down the current tap (if any) and installs a fresh one.
    /// Used by the onboarding flow to live-activate the hotkey immediately
    /// after the user grants Input Monitoring, without an app relaunch.
    ///
    /// Must be called on the thread whose run loop pumps the tap — call
    /// install() and reinstall() from the same thread (main).
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

    /// C-callback trampoline. `CGEventTapCreate`'s callback is a
    /// non-capturing C function pointer, so it cannot close over `self`
    /// directly — `install()` passes `self` as an unretained opaque pointer
    /// via `userInfo`, and this unwraps it back to a `HotkeyMonitor`.
    private static func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        refcon: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

        // The system can disable a tap under load (timeout) or when the
        // user is interacting with a secure input field; re-enable it
        // rather than leaving the hotkey dead for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
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

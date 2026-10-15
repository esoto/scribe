import Foundation

/// Hold-to-talk keys. The CGEventTap listener needs the Input Monitoring TCC grant.
enum HotKey: String, CaseIterable {
    case rightCommand = "right_command"
    case rightOption = "right_option"
    case f13 = "f13"

    var keycode: Int {
        switch self {
        case .rightCommand: return 54
        case .rightOption: return 61
        case .f13: return 105
        }
    }

    /// Device-side bits from IOLLEvent.h (NX_DEVICERCMDKEYMASK, NX_DEVICERALTKEYMASK). The generic ⌘/⌥ bits
    /// (0x100000, 0x80000) stay set while the other-side key is held, so releasing Right ⌥ with Left ⌥ down
    /// never produced .up and left the mic recording.
    var modifierMask: UInt64? {
        switch self {
        case .rightCommand: return 0x10
        case .rightOption: return 0x40
        case .f13: return nil
        }
    }

    var displayName: String {
        switch self {
        case .rightCommand: return "Right \u{2318}"
        case .rightOption: return "Right \u{2325}"
        case .f13: return "F13"
        }
    }
}

enum KeyAction {
    case down
    case up
}

private let keyDownEventType = 10
private let keyUpEventType = 11
private let flagsChangedEventType = 12

final class KeyStateMachine {
    private let keycode: Int
    private let mask: UInt64?
    private var isDown = false

    init(key: HotKey) {
        self.keycode = key.keycode
        self.mask = key.modifierMask
    }

    func handle(eventType: Int, keycode: Int, flags: UInt64) -> KeyAction? {
        guard keycode == self.keycode else { return nil }

        let pressed: Bool
        if let mask {
            guard eventType == flagsChangedEventType else { return nil }
            pressed = (flags & mask) != 0
        } else if eventType == keyDownEventType {
            pressed = true
        } else if eventType == keyUpEventType {
            pressed = false
        } else {
            return nil
        }

        if pressed && !isDown {
            isDown = true
            return .down
        }
        if !pressed && isDown {
            isDown = false
            return .up
        }
        return nil
    }

    /// Forgets a held key and reports whether one was held. For tap re-enable, when the release may have been missed.
    func reset() -> Bool {
        defer { isDown = false }
        return isDown
    }
}

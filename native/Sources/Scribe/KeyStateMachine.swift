import Foundation

/// Hold-to-talk key detection.
///
/// KeyStateMachine is pure (unit-tested); a future CGEventTap-backed listener
/// wires it up and needs the Input Monitoring TCC grant.
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

    /// Modifier flag mask for keys detected via flagsChanged; nil for keys
    /// detected via keyDown/keyUp (e.g. f13).
    var modifierMask: UInt64? {
        switch self {
        case .rightCommand: return 0x100000
        case .rightOption: return 0x80000
        case .f13: return nil
        }
    }

    /// Human-readable label for the onboarding "try it" prompt.
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
}

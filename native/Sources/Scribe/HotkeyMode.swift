import Foundation

/// How the hotkey starts and stops a dictation. Hold is the default and what the privacy copy promises
/// ("the mic is captured only while the key is held"); latching is opt-in and says so in Settings.
enum HotkeyMode: String, CaseIterable {
    case hold = "hold"
    case holdOrLatch = "hold_or_latch"

    var displayName: String {
        switch self {
        case .hold: return "Hold to talk"
        case .holdOrLatch: return "Hold, or double-tap to latch"
        }
    }
}

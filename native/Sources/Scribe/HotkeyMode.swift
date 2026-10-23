import Foundation

/// How the hotkey starts and stops a dictation. Hold is the default; latching is opt-in and says so in Settings.
/// The privacy copy promises the mic only while recording, so every way a recording starts has a way it ends.
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

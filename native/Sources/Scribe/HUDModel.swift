import Foundation

/// What the recording pill shows. `result` is the one-line verdict after a dictation ("Pasted", "Pasted raw — …");
/// `problem` is the same one-liner for a failure, with the ⚠ the menu bar uses for it.
enum HUDPhase: Equatable {
    case hidden, listening, processing
    case result(String)
    case problem(String)
}

func hudGlyph(_ phase: HUDPhase) -> String {
    switch phase {
    case .hidden: return ""
    case .listening: return "●"
    case .processing: return "⋯"
    case .result: return "◦"
    case .problem: return "⚠"
    }
}

func hudLabel(_ phase: HUDPhase) -> String {
    switch phase {
    case .hidden: return ""
    case .listening: return "Listening"
    case .processing: return "Transcribing…"
    case .result(let text): return text
    case .problem(let text): return text
    }
}

/// Microphone RMS to a 0…1 meter: -60 dBFS (under a whisper, over a quiet room) is flat and -10 dBFS is full, so
/// normal speech (-40…-20 dBFS) lights two to four bars and a quiet mic that still passes the energy gate moves.
func hudLevel(rms: Double) -> Double {
    guard rms > 0 else { return 0 }
    let db = 20 * log10(rms)
    return min(1, max(0, (db + 60) / 50))
}

/// Bar `index` of five fills over its fifth of the range (0.0–0.2, 0.2–0.4, …), so speech lights the bars one by one
/// and silence leaves all five flat.
func barHeight(_ level: Double, index: Int) -> Double {
    min(1, max(0, (level - 0.2 * Double(index)) / 0.2))
}

/// The pill's state. The coordinator drives it from pipeline state, hints and the paste cue; `level` decays
/// between chunks so the bars fall instead of flickering.
@MainActor
final class HUDModel: ObservableObject {
    @Published private(set) var phase: HUDPhase = .hidden
    @Published private(set) var level: Double = 0

    /// How long a result stays before the pill hides. Nonisolated because the coordinator reads it as a default argument.
    nonisolated static let resultSeconds: Double = 1.2

    func show(_ next: HUDPhase) {
        if next != phase { phase = next }
        if next != .listening, level != 0 { level = 0 }
    }

    func hide() { show(.hidden) }

    /// Only while listening; otherwise a late chunk would move bars that are not on screen.
    func setLevel(rms: Double) {
        guard phase == .listening else { return }
        let decayed = max(hudLevel(rms: rms), level * 0.6)
        // The change threshold below would otherwise strand the bars just above flat after the last word.
        let next = decayed < 0.025 ? 0 : decayed
        if abs(next - level) > 0.01 { level = next }
    }
}

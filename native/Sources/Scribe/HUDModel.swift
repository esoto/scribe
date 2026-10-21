import Foundation

/// What the recording pill shows. `result` is the one-line verdict after a dictation ("Pasted", "Pasted raw — …").
enum HUDPhase: Equatable {
    case hidden, listening, processing
    case result(String)
}

func hudGlyph(_ phase: HUDPhase) -> String {
    switch phase {
    case .hidden: return ""
    case .listening: return "●"
    case .processing: return "⋯"
    case .result: return "◦"
    }
}

func hudLabel(_ phase: HUDPhase) -> String {
    switch phase {
    case .hidden: return ""
    case .listening: return "Listening"
    case .processing: return "Transcribing…"
    case .result(let text): return text
    }
}

/// Microphone RMS to a 0…1 meter on a decibel scale: -50 dBFS and below is silence, 0 dBFS is full.
func hudLevel(rms: Double) -> Double {
    guard rms > 0 else { return 0 }
    let db = 20 * log10(rms)
    return min(1, max(0, (db + 50) / 50))
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

    /// How long a result stays before the pill hides.
    static let resultSeconds: Double = 1.2

    func show(_ next: HUDPhase) {
        if next != phase { phase = next }
        if next != .listening, level != 0 { level = 0 }
    }

    func hide() { show(.hidden) }

    /// Only while listening; otherwise a late chunk would move bars that are not on screen.
    func setLevel(rms: Double) {
        guard phase == .listening else { return }
        let next = max(hudLevel(rms: rms), level * 0.6)
        if abs(next - level) > 0.01 { level = next }
    }
}

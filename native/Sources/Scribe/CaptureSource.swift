import Foundation

/// The microphone the audio engine is on, and whether it is the one the person chose. A wrong input used to stay
/// invisible because the picker only ever showed the choice.
struct CaptureSource: Equatable {
    let name: String
    let matchesSelection: Bool
}

extension CaptureSource {
    /// - Parameters:
    ///   - bound: the input the engine is bound to.
    ///   - preferredUID: the saved choice; nil means the system default.
    ///   - defaultUID: the system's default input; nil when it can't be read, since then nothing can be called wrong.
    init(bound: BoundInput, preferredUID: String?, defaultUID: String?) {
        let expected = preferredUID ?? defaultUID
        self.init(name: bound.name, matchesSelection: expected.map { $0 == bound.uid } ?? true)
    }

    /// Shared by Settings › Audio and the Doctor's microphone row, so the two cannot disagree.
    static func caption(_ source: CaptureSource?) -> String {
        guard let source else { return "Not recorded yet" }
        let sentence = "Capturing from: \(source.name)"
        return source.matchesSelection ? sentence : "\(sentence) — not the microphone you chose"
    }
}

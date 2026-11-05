import Foundation

/// The microphone the audio engine is on, and whether it is the one the person chose. A wrong input used to stay
/// invisible because the picker only ever showed the choice.
struct CaptureSource: Equatable {
    let name: String
    let matchesSelection: Bool
}

/// What the indicator can say. "Not recorded yet" and "could not read" are different facts: the second is about a
/// recording that did happen.
enum CaptureStatus: Equatable {
    /// Nothing has been bound since launch, or since a choice made without the microphone grant.
    case notRecordedYet
    /// The engine was read and its input could not be worked out.
    case unknown
    case source(CaptureSource)
}

extension CaptureStatus {
    /// - Parameters:
    ///   - bound: the input the engine is bound to; nil when it can't be read.
    ///   - preferredUID: the saved choice; nil means the system default.
    ///   - defaultInput: the system's default input; nil when it can't be read, since then nothing can be called wrong.
    init(bound: BoundInput?, preferredUID: String?, defaultInput: BoundInput?) {
        guard let bound else {
            self = .unknown
            return
        }
        var input = bound
        // CoreAudio's default-device aggregate is how the engine follows the default input, and the person never
        // chose it. It is the system default, so it is named and judged as that device.
        if AudioDevices.isDefaultAggregate(uid: bound.uid) {
            guard let defaultInput else {
                self = .unknown
                return
            }
            input = defaultInput
        }
        let expected = preferredUID ?? defaultInput?.uid
        self = .source(CaptureSource(name: input.name, matchesSelection: expected.map { $0 == input.uid } ?? true))
    }

    /// The engine is on a microphone other than the chosen one; an unreadable or absent reading flags nothing.
    var isMismatch: Bool {
        if case .source(let source) = self { return !source.matchesSelection }
        return false
    }

    /// Shared by Settings › Audio and the Doctor's microphone row, so the two cannot disagree.
    var caption: String {
        switch self {
        case .notRecordedYet: return "Not recorded yet"
        case .unknown: return "Capturing from: unknown — the input could not be read"
        case .source(let source):
            let sentence = "Capturing from: \(source.name)"
            return source.matchesSelection ? sentence : "\(sentence) — not the microphone you chose"
        }
    }
}

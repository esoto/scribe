import Foundation

/// A whole utterance that is an instruction to scribe rather than text to paste. Only the entire utterance is
/// matched here; a break phrase inside a sentence is BreakSplitter's job.
enum VoiceCommand: Equatable, CaseIterable {
    case pressReturn, newLine, newParagraph, undo

    /// The status-row verdict after the command ran.
    var hint: String {
        switch self {
        case .pressReturn: return "Return sent"
        case .newLine: return "New line"
        case .newParagraph: return "New paragraph"
        case .undo: return "Undo sent"
        }
    }

    /// What scribe.log records; never the utterance.
    var logName: String {
        switch self {
        case .pressReturn: return "return"
        case .newLine: return "new_line"
        case .newParagraph: return "new_paragraph"
        case .undo: return "undo"
        }
    }

    /// Folded (lowercase, no accents, no punctuation) phrases, EN and ES side by side. A bare "send" is left out:
    /// "Send." is a plausible one-word reply. Internal so a test can pin the break phrases to `BreakSplitter`'s table.
    static let phrases: [String: VoiceCommand] = [
        "enter": .pressReturn, "press enter": .pressReturn, "send it": .pressReturn, "send that": .pressReturn,
        "enviar": .pressReturn, "envialo": .pressReturn, "mandalo": .pressReturn, "presiona enter": .pressReturn,
        "new line": .newLine, "newline": .newLine, "line break": .newLine, "new line break": .newLine,
        "nueva linea": .newLine, "linea nueva": .newLine, "salto de linea": .newLine,
        "new lines": .newLine,
        "new paragraph": .newParagraph, "nuevo parrafo": .newParagraph, "parrafo nuevo": .newParagraph,
        "scratch that": .undo, "undo that": .undo, "undo": .undo,
        "borra eso": .undo, "deshacer": .undo, "deshace eso": .undo,
    ]

    /// The same phrases as folded words, for a matcher that walks an utterance word by word.
    static let phraseTokens: Set<[String]> = Set(phrases.keys.map { $0.split(separator: " ").map(String.init) })

    /// Tolerates ASR casing, accents and punctuation ("Send it." → send it). nil for anything else.
    static func match(_ utterance: String) -> VoiceCommand? {
        phrases[fold(utterance)]
    }

    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let letters = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.punctuationCharacters.contains(scalar) ? " " : Character(scalar)
        }
        return String(letters).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

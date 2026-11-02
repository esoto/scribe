import Foundation

enum EditRejection: String, Equatable {
    case empty, answered, length, language, newFacts, timeout
}

enum EditVerdict: Equatable {
    case accepted(String)
    case rejected(EditRejection)
}

/// Deterministic checks on an edit result. The first failure rejects; a rejection pastes nothing, so these are
/// deliberately strict — a wrong edit in the user's document costs more than a retry.
enum EditGates {
    static func accept(verb: EditVerb, selection: String, result: String) -> EditVerdict {
        let out = normalize(result, verb: verb)
        guard !out.isEmpty else { return .rejected(.empty) }
        guard !answered(out, selection: selection, verb: verb) else { return .rejected(.answered) }
        let ratio = Double(out.count) / Double(max(1, selection.count))
        guard ratio >= verb.lengthBand.low, ratio <= verb.lengthBand.high else { return .rejected(.length) }
        guard languageOk(selection: selection, result: out, verb: verb) else { return .rejected(.language) }
        guard !introducesNewFacts(selection: selection, result: out, verb: verb) else { return .rejected(.newFacts) }
        return .accepted(out)
    }

    /// A list keeps its line structure (at most one blank line in a row); everything else collapses like cleanup does.
    static func normalize(_ text: String, verb: EditVerb) -> String {
        guard verb.keepsNewlines else { return Gates.normalize(text) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        var kept: [String] = []
        for line in lines {
            if line.isEmpty, kept.last?.isEmpty == true { continue }
            kept.append(line)
        }
        while kept.first?.isEmpty == true { kept.removeFirst() }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    private static let preambles = ["here is", "here's", "sure", "of course", "certainly", "claro", "aqui tienes", "por supuesto"]

    /// The model talked instead of editing: a tag, the instruction echoed, or a preamble the selection itself did not
    /// open with ("Claro que sí…" as a selection is not an answer).
    static func answered(_ result: String, selection: String, verb: EditVerb) -> Bool {
        let lower = result.lowercased()
        if lower.contains("<text") || lower.contains("<instruction") { return true }
        if VoiceCommand.fold(result).hasPrefix(VoiceCommand.fold(verb.instruction)) { return true }
        return opensWithPreamble(result) && !opensWithPreamble(selection)
    }

    private static func opensWithPreamble(_ text: String) -> Bool {
        let folded = VoiceCommand.fold(text)
        return preambles.contains { folded == $0 || folded.hasPrefix($0 + " ") }
    }

    static func languageOk(selection: String, result: String, verb: EditVerb) -> Bool {
        switch verb {
        case .toSpanish: return Gates.langScore(result) <= -2
        case .toEnglish: return Gates.langScore(result) >= 2
        default: return Gates.languageConsistent(raw: selection, cleaned: result)
        }
    }

    /// Numbers (digit runs) absent from the selection are new facts for every verb; capitalised words absent from
    /// the selection are new facts unless the verb translates (Monday → lunes) or the word opens a sentence.
    static func introducesNewFacts(selection: String, result: String, verb: EditVerb) -> Bool {
        let selectionNumbers = Set(numbers(in: selection))
        if numbers(in: result).contains(where: { !selectionNumbers.contains($0) }) { return true }
        guard !verb.isTranslation else { return false }
        let selectionCaps = Set(capitalisedWords(in: selection, includingSentenceStarts: true).map { $0.lowercased() })
        return capitalisedWords(in: result, includingSentenceStarts: false)
            .contains { !selectionCaps.contains($0.lowercased()) }
    }

    static func numbers(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isNumber }).map(String.init)
    }

    /// Words starting with an uppercase letter; with `includingSentenceStarts` false, a word right after the start of
    /// the text, ".", "?", "!", ":" or a newline is skipped, because it is capitalised by position, not by meaning.
    static func capitalisedWords(in text: String, includingSentenceStarts: Bool) -> [String] {
        var out: [String] = []
        var atSentenceStart = true
        var word = ""
        func flush() {
            if let first = word.first, first.isUppercase, includingSentenceStarts || !atSentenceStart { out.append(word) }
            if !word.isEmpty { atSentenceStart = false }
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch == "'" || ch == "’" {
                word.append(ch)
            } else {
                flush()
                if ".?!:\n".contains(ch) { atSentenceStart = true }
            }
        }
        flush()
        return out
    }

    static func pillReason(_ rejection: EditRejection, modelIsGemma4: Bool) -> String {
        let why: String
        switch rejection {
        case .empty: why = "came back empty"
        case .answered: why = "answered instead of editing"
        case .length: why = "length off"
        case .language: why = "language changed"
        case .newFacts: why = "added something new"
        case .timeout: why = "took too long"
        }
        return "Edit rejected — \(why)" + (modelIsGemma4 ? "" : " · Gemma 4 does this better")
    }
}

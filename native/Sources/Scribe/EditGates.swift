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
    /// Under this many words a translation is rejected only for a score clearly on the wrong side: a greeting scores
    /// about 0, so requiring ±2 would reject every correct one, but an English "translation" that scores 2 is still English.
    static let minWordsForTranslationLanguageGate = 6

    static func accept(verb: EditVerb, selection: String, result: String) -> EditVerdict {
        let out = normalize(result, verb: verb)
        guard !out.isEmpty else { return .rejected(.empty) }
        guard !answered(out, selection: selection, verb: verb) else { return .rejected(.answered) }
        guard lengthOk(verb: verb, selection: selection, result: out) else { return .rejected(.length) }
        guard languageOk(selection: selection, result: out, verb: verb) else { return .rejected(.language) }
        guard !introducesNewFacts(selection: selection, result: out, verb: verb) else { return .rejected(.newFacts) }
        return .accepted(out)
    }

    /// Result characters over selection characters, the number the length gate judges; nil when either is empty.
    /// Pass the normalised result, as `accept` does.
    static func lengthRatio(selection: String, result: String) -> Double? {
        guard !selection.isEmpty, !result.isEmpty else { return nil }
        return Double(result.count) / Double(selection.count)
    }

    private static func lengthOk(verb: EditVerb, selection: String, result: String) -> Bool {
        guard let ratio = lengthRatio(selection: selection, result: result) else { return false }
        let band = verb.lengthBand
        return band.low <= ratio && ratio <= band.high
    }

    /// A list keeps its line structure (at most one blank line in a row); everything else collapses like cleanup does.
    static func normalize(_ text: String, verb: EditVerb) -> String {
        guard verb.keepsNewlines else { return Gates.normalize(text) }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
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

    /// Stored folded because the result is folded before matching, and folding turns the apostrophe of "here's" into a space.
    static let preambles = ["here s", "here is", "sure", "of course", "certainly", "claro", "aqui tienes", "por supuesto"]

    private static let promptTags = ["<text", "<instruction", "</text", "</instruction"]

    /// The model talked instead of editing: a tag, the instruction echoed, or a preamble the selection itself did not
    /// open with ("Claro que sí…" as a selection is not an answer). A tag counts the same way — only when the selection
    /// does not carry that tag itself, because a faithful edit of a pasted prompt keeps the literal "</text>" it was given.
    static func answered(_ result: String, selection: String, verb: EditVerb) -> Bool {
        let lower = result.lowercased()
        let selectionLower = selection.lowercased()
        if promptTags.contains(where: { lower.contains($0) && !selectionLower.contains($0) }) { return true }
        if VoiceCommand.fold(result).hasPrefix(VoiceCommand.fold(verb.instruction)) { return true }
        return opensWithPreamble(result) && !opensWithPreamble(selection)
    }

    private static func opensWithPreamble(_ text: String) -> Bool {
        let folded = VoiceCommand.fold(text)
        return preambles.contains { folded == $0 || folded.hasPrefix($0 + " ") }
    }

    static func languageOk(selection: String, result: String, verb: EditVerb) -> Bool {
        switch verb {
        case .toSpanish: return isTooShortToScore(result) ? Gates.langScore(result) < 2 : Gates.langScore(result) <= -2
        case .toEnglish: return isTooShortToScore(result) ? Gates.langScore(result) > -2 : Gates.langScore(result) >= 2
        default: return Gates.languageConsistent(raw: selection, cleaned: result)
        }
    }

    private static func isTooShortToScore(_ result: String) -> Bool {
        result.split(whereSeparator: { $0.isWhitespace }).count < minWordsForTranslationLanguageGate
    }

    /// Numbers (digit runs) absent from the selection are new facts for every verb. A capitalised word is a new fact
    /// only if the selection never had it in any case or accent (fix grammar may capitalise "monday" or restore "Lucía"),
    /// unless the verb translates (Monday → lunes), the word opens a sentence, or it is AM or PM in any spelling.
    static func introducesNewFacts(selection: String, result: String, verb: EditVerb) -> Bool {
        let selectionNumbers = Set(numbers(in: selection))
        if numbers(in: result).contains(where: { !selectionNumbers.contains($0) }) { return true }
        guard !verb.isTranslation else { return false }
        let known = Set(words(in: selection).flatMap { [VoiceCommand.fold($0.text), VoiceCommand.fold(stemAndTail($0.text).stem)] })
        return words(in: joiningMeridiemDots(result)).contains { word in
            guard !word.opensSentence, word.text.first?.isUppercase == true else { return false }
            if meridiems.contains(word.text.lowercased()) { return false }
            if known.contains(VoiceCommand.fold(word.text)) { return false }
            // "I'll" and "Marcos's" are a known word plus a clitic; "O'Brien" is not "O" plus anything.
            let (stem, tail) = stemAndTail(word.text)
            return !((1...2).contains(tail.count) && known.contains(VoiceCommand.fold(stem)))
        }
    }

    /// The digit runs of `text`. A run followed by ":MM" (exactly two digits, so "9:5" and "9:456" do not count) is an
    /// hour, and the minutes are a format, not a fact: "a las 9" read back as "9:00" is the same hour, and so is "9:45",
    /// because the gate exists to catch a changed hour and not to audit the minutes a model chose to spell out.
    static func numbers(in text: String) -> [String] {
        let chars = Array(text)
        var runs: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else {
                i += 1
                continue
            }
            var end = i
            while end < chars.count, chars[end].isNumber { end += 1 }
            runs.append(String(chars[i..<end]))
            i = indexAfterMinutes(chars, from: end)
        }
        return runs
    }

    /// Skips each ":MM" that follows, so "9:00:00" is the hour 9 too.
    private static func indexAfterMinutes(_ chars: [Character], from start: Int) -> Int {
        var i = start
        while i + 2 < chars.count, chars[i] == ":", chars[i + 1].isNumber, chars[i + 2].isNumber,
            !(i + 3 < chars.count && chars[i + 3].isNumber)
        {
            i += 3
        }
        return i
    }

    private static let meridiems: Set<String> = ["am", "pm"]

    /// "a.m." and "p.m." (any case) become "am." and "pm.", so their letters are one word that `meridiems` excuses
    /// and the final dot still ends a sentence, as it did before the marker was excused.
    private static func joiningMeridiemDots(_ text: String) -> String {
        text.replacingOccurrences(of: "\\b([ap])\\.(m)\\b", with: "$1$2", options: [.regularExpression, .caseInsensitive])
    }

    private static func isApostrophe(_ ch: Character) -> Bool { ch == "'" || ch == "’" }

    /// "I'll" → ("I", "ll"); a word without an apostrophe has an empty tail.
    private static func stemAndTail(_ word: String) -> (stem: String, tail: String) {
        guard let apostrophe = word.firstIndex(where: isApostrophe) else { return (word, "") }
        return (String(word[..<apostrophe]), String(word[word.index(after: apostrophe)...]))
    }

    /// Words in order, with edge apostrophes trimmed so a quote mark ('Lucía') cannot hide a capital, each flagged when it
    /// opens a sentence: at the start of the text or after ".", "?", "!" or a newline (CRLF included). A colon does not,
    /// because "due Tuesday: Lucía will send it" is exactly where a model slips in a name.
    static func words(in text: String) -> [(text: String, opensSentence: Bool)] {
        var out: [(text: String, opensSentence: Bool)] = []
        var atSentenceStart = true
        var token = ""
        func flush() {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
            token = ""
            guard !word.isEmpty else { return }
            out.append((word, atSentenceStart))
            atSentenceStart = false
        }
        for ch in text {
            if ch.isLetter || isApostrophe(ch) {
                token.append(ch)
            } else {
                flush()
                if ".?!".contains(ch) || ch.isNewline { atSentenceStart = true }
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

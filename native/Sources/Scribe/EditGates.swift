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

    /// The two language-hint sentences exactly as the model is sent them, folded like the instruction echo is.
    private static let foldedHints = [EditPrompt.englishHint, EditPrompt.spanishHint].map(VoiceCommand.fold)

    /// The model talked instead of editing: a tag, the instruction or a language hint echoed, or a preamble the
    /// selection itself did not open with ("Claro que sí…" as a selection is not an answer). A tag counts the same way —
    /// only when the selection does not carry that tag itself, because a faithful edit of a pasted prompt keeps the
    /// literal "</text>" it was given.
    static func answered(_ result: String, selection: String, verb: EditVerb) -> Bool {
        let lower = result.lowercased()
        let selectionLower = selection.lowercased()
        if promptTags.contains(where: { lower.contains($0) && !selectionLower.contains($0) }) { return true }
        let folded = VoiceCommand.fold(result)
        if folded.hasPrefix(VoiceCommand.fold(verb.instruction)) { return true }
        // Gate 5 stops an echoed hint only by accident ("English" is a new capitalised word), which fails as soon as
        // the selection itself names a language.
        if foldedHints.contains(where: { folded.hasPrefix($0) }) { return true }
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

    /// Numbers (digit runs) absent from the selection are new facts for every verb, unless they are one fact spelled
    /// another way: leading zeros ("08:00" and "8:00 AM"), the same hour on the other clock, or the ":00" a bare hour
    /// gains. A minute is a fact once stated: a result time "H:MM" is known when the selection states that hour with
    /// the same minutes, or states the bare hour and the result's minutes are 00, so "at 9" may become "9:00" but
    /// never "9:45", and "3:30" never "3:45". A result bare hour is known when the selection has that hour with or
    /// without minutes. A capitalised word is a new fact only if the selection never had it in any case or accent (fix
    /// grammar may capitalise "monday" or restore "Lucía"), unless the verb translates (Monday → lunes), the word opens
    /// a sentence, or it is AM or PM in any spelling.
    static func introducesNewFacts(selection: String, result: String, verb: EditVerb) -> Bool {
        if introducesNewNumbers(selection: selection, result: result) { return true }
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

    private enum Meridiem { case am, pm }

    /// One digit run. `digits` has its leading zeros stripped ("08" → "8", "000" → "0"). `minutes` is the ":MM" or
    /// ":MM:SS" that followed it, nil for a bare number, and "00" for any all-zero tail so "9:00" and "9:00:00" agree.
    private struct NumberToken {
        let digits: String
        let minutes: String?
        let meridiem: Meridiem?
    }

    private static let onTheHour = "00"

    private static func introducesNewNumbers(selection: String, result: String) -> Bool {
        let selectionTokens = numberTokens(in: selection)
        return numberTokens(in: result).contains { token in
            !selectionTokens.contains { isKnown(token, from: $0) }
        }
    }

    /// The result number `r` says nothing the selection number `s` did not. The hour must match (see `isSameHour`).
    /// Minutes are compared as facts: a result's minutes must be the ones `s` states, or "00" when `s` is a bare hour,
    /// because a model that writes "9" as "9:00" has added a format and no information, and "9:45" has added a time.
    /// A bare result number has no minutes to check.
    private static func isKnown(_ r: NumberToken, from s: NumberToken) -> Bool {
        guard isSameHour(r, s) else { return false }
        guard let minutes = r.minutes else { return true }
        return minutes == s.minutes || (s.minutes == nil && minutes == onTheHour)
    }

    /// A model that translates "a las 15:00" writes "3:00 PM", and 15 and 3 are one hour, so a result number is not new
    /// when the selection names its hour on the other clock. Only PM reaches the afternoon ("3 AM" is 03:00), and only
    /// 1…11 PM against 13…23, because 12 PM is already 12; any other mismatch is a changed hour, which is what this gate
    /// is for.
    ///
    /// Only the 12-hour side has evidence that the number is a time: the PM marker. A result 13…23 is excused by a
    /// selection "3 PM" and a result "3 PM" by a selection 15, but nothing says the 15 is a clock hour, so "deliver the
    /// 15 boxes" → "deliver the 15 boxes at 3 PM" passes with an invented time. The hole needs a coincidence of values
    /// and is recorded here, not closed.
    private static func isSameHour(_ r: NumberToken, _ s: NumberToken) -> Bool {
        if r.digits == s.digits { return true }
        guard let hour = Int(r.digits), let other = Int(s.digits) else { return false }
        if r.meridiem == .pm, (1...11).contains(hour), other == hour + 12 { return true }
        return (13...23).contains(hour) && s.meridiem == .pm && other == hour - 12
    }

    /// The digit runs of `text` with leading zeros stripped; the ":MM" (":SS") after a run is part of that run, so
    /// "9:45" lists as 9. The minutes are kept in `numberTokens` for `introducesNewFacts`, which judges them.
    static func numbers(in text: String) -> [String] {
        numberTokens(in: text).map(\.digits)
    }

    private static func numberTokens(in text: String) -> [NumberToken] {
        let chars = Array(text)
        var tokens: [NumberToken] = []
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else {
                i += 1
                continue
            }
            var end = i
            while end < chars.count, chars[end].isNumber { end += 1 }
            let (minutes, afterMinutes) = minutesAfter(chars, from: end)
            tokens.append(
                NumberToken(
                    digits: strippingLeadingZeros(String(chars[i..<end])), minutes: minutes,
                    meridiem: meridiem(in: chars, from: afterMinutes)))
            i = afterMinutes
        }
        return tokens
    }

    /// Spanish 24-hour text writes "08:00" and a translation writes "8:00 AM": the zero is spelling, not a fact. A run of
    /// zeros stays one zero, so "0" is still a number and never an empty one.
    private static func strippingLeadingZeros(_ digits: String) -> String {
        let rest = digits.drop(while: { $0 == "0" })
        return rest.isEmpty ? "0" : String(rest)
    }

    /// The marker right after a number: optional spaces (the no-break ones macOS writes included, a newline not), then
    /// "am", "pm", "a.m." or "p.m." in any case. A Spanish model also writes the RAE's "a. m." and "p. m." with a space
    /// after each dot, which would otherwise leave the hour with no marker to convert. A letter after it means a longer
    /// word, so "3 amigos" is not "3 am".
    private static func meridiem(in chars: [Character], from start: Int) -> Meridiem? {
        var i = start
        skipSpaces(chars, &i)
        guard i < chars.count else { return nil }
        let first = chars[i].lowercased()
        guard first == "a" || first == "p" else { return nil }
        i += 1
        if i < chars.count, chars[i] == "." {
            i += 1
            skipSpaces(chars, &i)
        }
        guard i < chars.count, chars[i].lowercased() == "m" else { return nil }
        i += 1
        if i < chars.count, chars[i].isLetter { return nil }
        return first == "p" ? .pm : .am
    }

    private static func skipSpaces(_ chars: [Character], _ i: inout Int) {
        while i < chars.count, chars[i].isWhitespace, !chars[i].isNewline { i += 1 }
    }

    /// Each ":MM" that follows an hour (exactly two digits, so "9:5" and "9:456" are not minutes), joined by colons, and
    /// the index after them. "9:00:00" is "9:00", so every all-zero tail reads "00".
    private static func minutesAfter(_ chars: [Character], from start: Int) -> (minutes: String?, next: Int) {
        var groups: [String] = []
        var i = start
        while i + 2 < chars.count, chars[i] == ":", chars[i + 1].isNumber, chars[i + 2].isNumber,
            !(i + 3 < chars.count && chars[i + 3].isNumber)
        {
            groups.append(String(chars[(i + 1)...(i + 2)]))
            i += 3
        }
        guard !groups.isEmpty else { return (nil, start) }
        return (groups.allSatisfy { $0 == onTheHour } ? onTheHour : groups.joined(separator: ":"), i)
    }

    private static let meridiems: Set<String> = ["am", "pm"]

    /// "a.m.", "p.m." and the RAE's "a. m." (any case) become "am." and "pm.", so their letters are one word that
    /// `meridiems` excuses and the final dot still ends a sentence, as it did before the marker was excused.
    private static func joiningMeridiemDots(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\b([ap])\\.[^\\S\\r\\n]*(m)\\b", with: "$1$2", options: [.regularExpression, .caseInsensitive])
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

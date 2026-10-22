import Foundation

/// Where a dictation breaks when the user said "new line" or "new paragraph" inside it.
enum Break: Equatable {
    case line, paragraph

    var text: String {
        switch self {
        case .line: return "\n"
        case .paragraph: return "\n\n"
        }
    }
}

/// A run of dictated words and the break that follows it (nil for the last run).
struct Segment: Equatable {
    var text: String
    var breakAfter: Break?
}

/// Splits a transcript at spoken break phrases so each run can be cleaned on its own and the runs joined with
/// real line breaks — the cleanup model never sees a break phrase or a newline. Whole-token matching only,
/// folded like `VoiceCommand` (case, accents, punctuation), so "newline" matches and "newlines" does not.
/// A phrase right after "the words" (`EscapePhrase`) is text: the escape words are dropped and the phrase stays.
enum BreakSplitter {
    /// Folded token sequences → break. Kept in step with `VoiceCommand`'s table by tests in both directions.
    static let phrases: [[String]: Break] = [
        ["new", "line"]: .line, ["newline"]: .line, ["line", "break"]: .line, ["new", "line", "break"]: .line,
        ["nueva", "linea"]: .line, ["linea", "nueva"]: .line, ["salto", "de", "linea"]: .line,
        ["new", "lines"]: .line,
        ["new", "paragraph"]: .paragraph, ["nuevo", "parrafo"]: .paragraph, ["parrafo", "nuevo"]: .paragraph,
    ]
    /// From the table, so a longer phrase added later cannot silently never match.
    private static let longest = phrases.keys.map(\.count).max() ?? 1

    /// These carry meaning at the end of a line ("Agenda:" before a list), so they survive a break.
    private static let keptMarks: Set<Character> = [".", "?", "!", ":", "…"]

    /// Empty runs are dropped: a break at the start or end of the utterance means nothing, and two breaks in a
    /// row collapse into the larger one. A comma or semicolon dangling before a break, and punctuation standing
    /// alone beside it, are ASR's guess at a pause rather than text, so the join drops them.
    static func split(_ raw: String) -> [Segment] {
        let (tokens, folded) = tokenize(raw)
        let escapes = EscapePhrase.resolve(folded: folded)

        var segments: [Segment] = []
        var run: [String] = []
        func close(with brk: Break?) {
            if brk != nil { trimBeforeBreak(&run) }
            if !run.isEmpty {
                segments.append(Segment(text: run.joined(separator: " "), breakAfter: brk))
                run = []
            } else if brk == .paragraph, let last = segments.indices.last {
                // A second break right after the first: keep the larger.
                segments[last].breakAfter = .paragraph
            }
        }

        var i = 0
        var afterBreak = false
        while i < tokens.count {
            if escapes.dropped.contains(i) {
                i += 1
            } else if let (length, brk) = phrase(in: folded, at: i, escaped: escapes.escaped) {
                close(with: brk)
                afterBreak = true
                i += length
            } else {
                // Right after a break (also a leading one), so a dash left over from the pause would otherwise start the line.
                if !(afterBreak && run.isEmpty && isStrayPunctuation(tokens[i])) {
                    run.append(tokens[i])
                    afterBreak = false
                }
                i += 1
            }
        }
        close(with: nil)
        if let last = segments.indices.last { segments[last].breakAfter = nil }
        return segments
    }

    /// The larger break among the phrases in `raw`, nil when there are none. For an utterance made only of break
    /// phrases, where `split` leaves no run to paste but the user still asked for a break.
    static func largestBreak(in raw: String) -> Break? {
        let folded = tokenize(raw).folded
        let escaped = EscapePhrase.resolve(folded: folded).escaped
        var largest: Break?
        var i = 0
        while i < folded.count {
            if let (length, brk) = phrase(in: folded, at: i, escaped: escaped) {
                largest = largest == .paragraph ? .paragraph : brk
                i += length
            } else {
                i += 1
            }
        }
        return largest
    }

    /// The pasted text: runs joined by their breaks.
    static func join(_ pieces: [(text: String, breakAfter: Break?)]) -> String {
        pieces.map { $0.text + ($0.breakAfter?.text ?? "") }.joined()
    }

    private static func tokenize(_ raw: String) -> (tokens: [String], folded: [String]) {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return (tokens, tokens.map { VoiceCommand.fold($0) })
    }

    /// Longest first, so "salto de linea" does not leave "salto de" behind as text. A window that touches an
    /// escaped word is text, including the tail of an escaped phrase ("line break" inside "new line break").
    private static func phrase(in folded: [String], at i: Int, escaped: Set<Int>) -> (length: Int, brk: Break)? {
        for length in stride(from: min(longest, folded.count - i), through: 1, by: -1) {
            let window = Array(folded[i..<(i + length)])
            if !window.contains(""), escaped.isDisjoint(with: i..<(i + length)), let brk = phrases[window] {
                return (length, brk)
            }
        }
        return nil
    }

    private static func isStrayPunctuation(_ token: String) -> Bool {
        VoiceCommand.fold(token).isEmpty && !token.contains(where: { keptMarks.contains($0) })
    }

    private static func trimBeforeBreak(_ run: inout [String]) {
        while let last = run.last, isStrayPunctuation(last) { run.removeLast() }
        guard var last = run.popLast() else { return }
        while let mark = last.last, mark == "," || mark == ";" { last.removeLast() }
        run.append(last)
    }
}

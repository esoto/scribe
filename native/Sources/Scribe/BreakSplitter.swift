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
enum BreakSplitter {
    /// Folded token sequences → break. Kept in step with `VoiceCommand`'s table by a test.
    static let phrases: [[String]: Break] = [
        ["new", "line"]: .line, ["newline"]: .line, ["line", "break"]: .line,
        ["nueva", "linea"]: .line, ["linea", "nueva"]: .line, ["salto", "de", "linea"]: .line,
        ["new", "paragraph"]: .paragraph, ["nuevo", "parrafo"]: .paragraph, ["parrafo", "nuevo"]: .paragraph,
    ]
    private static let longest = 3

    /// Empty runs are dropped: a break at the start or end of the utterance means nothing, and two breaks in a
    /// row collapse into the larger one.
    static func split(_ raw: String) -> [Segment] {
        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let folded = tokens.map { VoiceCommand.fold($0) }

        var segments: [Segment] = []
        var run: [String] = []
        func close(with brk: Break?) {
            if !run.isEmpty {
                segments.append(Segment(text: run.joined(separator: " "), breakAfter: brk))
                run = []
            } else if let brk, let last = segments.indices.last {
                // A second break right after the first: keep the larger.
                if segments[last].breakAfter == .line || segments[last].breakAfter == nil {
                    segments[last].breakAfter = brk == .paragraph ? .paragraph : segments[last].breakAfter ?? brk
                }
            }
        }

        var i = 0
        while i < tokens.count {
            var matched = false
            for length in stride(from: min(longest, tokens.count - i), through: 1, by: -1) {
                let window = Array(folded[i..<(i + length)])
                guard !window.contains(""), let brk = phrases[window] else { continue }
                close(with: brk)
                i += length
                matched = true
                break
            }
            if !matched {
                run.append(tokens[i])
                i += 1
            }
        }
        close(with: nil)
        if let last = segments.indices.last { segments[last].breakAfter = nil }
        return segments
    }

    /// The pasted text: runs joined by their breaks.
    static func join(_ pieces: [(text: String, breakAfter: Break?)]) -> String {
        pieces.map { $0.text + ($0.breakAfter?.text ?? "") }.joined()
    }
}

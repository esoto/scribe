import Foundation

/// Deterministic find/replace over whitespace tokens. Kept out of the LLM prompt: the model read `X -> Y` pairs as instructions and dropped words.
enum TermReplacer {
    /// Case-insensitive. An original may span several words; the longest match wins. Edge punctuation on
    /// the first and last matched token is kept; punctuation inside a phrase prevents a match.
    static func apply(_ pairs: [ReplacementPair], to text: String) -> String {
        apply(entries: pairs.map { ($0.original, $0.replacement, true) }, to: text)
    }

    /// One scan for mixed snippet kinds, so the longest trigger wins and no expansion is rescanned. An entry with
    /// `keepTrailing: false` drops sentence punctuation after its match only when the match ends the text, which is
    /// where ASR puts the period; closing brackets and quotes always stay.
    static func apply(
        entries: [(original: String, replacement: String, keepTrailing: Bool)], to text: String
    ) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }

        var lookup: [[String]: (replacement: String, keepTrailing: Bool)] = [:]
        var longest = 1
        for entry in entries {
            let key = words(entry.original)
            guard !key.isEmpty, !entry.replacement.isEmpty else { continue }
            lookup[key] = (entry.replacement, entry.keepTrailing)
            longest = max(longest, key.count)
        }
        guard !lookup.isEmpty else { return text }

        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        var i = 0
        while i < tokens.count {
            var advanced = false
            for length in stride(from: min(longest, tokens.count - i), through: 1, by: -1) {
                guard let stripped = strip(tokens[i..<(i + length)]),
                    let entry = lookup[stripped.cores]
                else { continue }
                let endsText = i + length == tokens.count
                let dropsSentenceMarks = !entry.keepTrailing && endsText
                let trailing = dropsSentenceMarks ? stripped.trailing.filter { !sentencePunctuation.contains($0) } : stripped.trailing
                // Spanish opens a question with ¿: when the closing ? goes, its opener must go too.
                let leading = dropsSentenceMarks ? stripped.leading.filter { !openingMarks.contains($0) } : stripped.leading
                out.append(leading + entry.replacement + trailing)
                i += length
                advanced = true
                break
            }
            if !advanced {
                out.append(tokens[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    /// Lowercased words of an original, whitespace-normalised.
    static func words(_ original: String) -> [String] {
        original.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Edge punctuation off both ends, as `strip` treats a matched window's outer tokens.
    static func trimEdges(_ text: String) -> String {
        var core = Substring(text)
        while let f = core.first, edgePunctuation.contains(f) { core.removeFirst() }
        while let l = core.last, edgePunctuation.contains(l) { core.removeLast() }
        return String(core)
    }

    /// nil when a token is empty after stripping, so punctuation-only tokens never match.
    private static func strip(_ window: ArraySlice<String>) -> (leading: String, cores: [String], trailing: String)? {
        var cores: [String] = []
        var leading = ""
        var trailing = ""
        let last = window.count - 1
        for (offset, token) in window.enumerated() {
            var core = Substring(token)
            if offset == 0 {
                while let f = core.first, edgePunctuation.contains(f) {
                    leading.append(f)
                    core.removeFirst()
                }
            }
            if offset == last {
                while let l = core.last, edgePunctuation.contains(l) {
                    trailing.insert(l, at: trailing.startIndex)
                    core.removeLast()
                }
            }
            guard !core.isEmpty else { return nil }
            cores.append(core.lowercased())
        }
        return (leading, cores, trailing)
    }

    private static let openingMarks: Set<Character> = ["¿", "¡"]
    private static let sentencePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "…"]

    private static let edgePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "¿", "¡", "\"", "'", "(", ")", "[", "]",
        "{", "}", "«", "»", "…", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
    ]
}

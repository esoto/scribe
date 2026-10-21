import Foundation

/// Deterministic find/replace over whitespace tokens. Kept out of the LLM prompt: the model read `X -> Y` pairs as instructions and dropped words.
enum TermReplacer {
    /// Case-insensitive. An original may span several words; the longest match wins. Edge punctuation on
    /// the first and last matched token is kept; punctuation inside a phrase prevents a match.
    static func apply(_ pairs: [ReplacementPair], to text: String) -> String {
        guard !pairs.isEmpty, !text.isEmpty else { return text }

        var lookup: [[String]: String] = [:]
        var longest = 1
        for pair in pairs {
            let key = words(pair.original)
            guard !key.isEmpty, !pair.replacement.isEmpty else { continue }
            lookup[key] = pair.replacement
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
                    let replacement = lookup[stripped.cores]
                else { continue }
                out.append(stripped.leading + replacement + stripped.trailing)
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

    private static let edgePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "¿", "¡", "\"", "'", "(", ")", "[", "]",
        "{", "}", "«", "»", "…", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
    ]
}

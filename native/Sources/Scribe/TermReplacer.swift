import Foundation

/// Deterministic whole-token find/replace. Kept out of the LLM prompt: the model read `X -> Y` pairs as instructions and dropped words.
enum TermReplacer {
    /// Matches per whitespace-delimited token, case-insensitively; multi-word originals never match.
    static func apply(_ pairs: [ReplacementPair], to text: String) -> String {
        guard !pairs.isEmpty, !text.isEmpty else { return text }

        var lookup: [String: String] = [:]
        for pair in pairs {
            let key = pair.original.trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !pair.replacement.isEmpty else { continue }
            lookup[key] = pair.replacement
        }
        guard !lookup.isEmpty else { return text }

        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        return tokens.map { token -> String in
            var core = Substring(token)
            var leading = ""
            var trailing = ""
            while let f = core.first, edgePunctuation.contains(f) {
                leading.append(f)
                core.removeFirst()
            }
            while let l = core.last, edgePunctuation.contains(l) {
                trailing.insert(l, at: trailing.startIndex)
                core.removeLast()
            }
            guard let replacement = lookup[core.lowercased()] else { return String(token) }
            return leading + replacement + trailing
        }
        .joined(separator: " ")
    }

    private static let edgePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "¿", "¡", "\"", "'", "(", ")", "[", "]",
        "{", "}", "«", "»", "…", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
    ]
}

import Foundation

/// Applies the user's manual replacement pairs to a transcript.
///
/// These used to be handed to the cleanup model as prompt instructions,
/// which was the wrong tool for a literal string substitution and cost real
/// output quality: the `"X" -> "Y"` rendering read as "X to Y", so a
/// transcript saying "deploy with camel to hetzner" looked like a
/// replacement rule and the model applied it, deleting a word. Worse, the
/// prompt only runs when cleanup runs — so a short utterance (under
/// `PipelineConfig.minWords`), a disabled cleanup toggle, a timeout, or a
/// tripped output gate all silently skipped the dictionary entirely, which
/// is exactly when a bare name needs correcting most.
///
/// Doing it here instead makes replacements deterministic, unconditional,
/// and incapable of dropping a word.
enum TermReplacer {
    /// Replaces whole words matching a pair's `original` (case-insensitively)
    /// with its `replacement`, preserving any punctuation attached to the
    /// token. Matching is per whitespace-delimited token, so a pair never
    /// rewrites the inside of a longer word: `camel` leaves `camelCase`
    /// alone. Multi-word originals are not matched.
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

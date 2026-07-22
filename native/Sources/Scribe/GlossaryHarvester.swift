import Foundation

/// Extracts glossary candidates — distinctive vocabulary worth teaching the
/// cleanup model — from a cleaned dictation. Pure and stateless; the store
/// owns counting, promotion, and decay.
enum GlossaryHarvester {
    /// Distinct candidate terms in `text`, deduped, first-occurrence order.
    /// Dedupe means a term counts at most once per dictation, so the store's
    /// promotion threshold reads as "seen in N distinct dictations".
    static func candidates(in text: String) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            // Line starts are sentence starts: splitting on newlines up front
            // is what lets us treat them as sentence terminators at all.
            var sentenceInitial = true
            for rawToken in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let token = trimEdgePunctuation(String(rawToken))
                if qualifies(token, sentenceInitial: sentenceInitial),
                    seen.insert(token).inserted
                {
                    results.append(token)
                }
                sentenceInitial = rawToken.last.map { sentenceTerminators.contains($0) } ?? true
            }
        }
        return results
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", ":"]

    private static let edgePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "¿", "¡", "\"", "'", "(", ")", "[", "]",
        "{", "}", "«", "»", "…", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
    ]

    /// Common capitalized words that must not be learned as proper nouns
    /// mid-sentence (rule 3 only). Case-sensitive on purpose.
    private static let stoplist: Set<String> = [
        "The", "This", "That", "These", "Those", "Los", "Las", "Una", "Uno",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December",
        "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto",
        "Septiembre", "Octubre", "Noviembre", "Diciembre",
        "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo",
    ]

    private static func trimEdgePunctuation(_ token: String) -> String {
        var s = Substring(token)
        while let f = s.first, edgePunctuation.contains(f) { s.removeFirst() }
        while let l = s.last, edgePunctuation.contains(l) { s.removeLast() }
        return String(s)
    }

    private static func qualifies(_ token: String, sentenceInitial: Bool) -> Bool {
        let count = token.count
        guard count >= 2, count <= 30 else { return false }
        guard token.contains(where: \.isLetter) else { return false }
        guard !token.contains("@"), !token.contains("://") else { return false }

        // Rule 1 — acronym (JSON, S3, MLX): allowed even sentence-initial;
        // an all-caps opener is far more likely an acronym than a word.
        if count <= 6, let first = token.first, first.isUppercase,
            token.allSatisfy({ ($0.isLetter && $0.isUppercase) || $0.isNumber })
        {
            return true
        }

        // Rule 2 — mixed-case / code-like (XcodeGen, snake_case, gemma3).
        let hasLower = token.contains(where: \.isLowercase)
        if token.dropFirst().contains(where: \.isUppercase) && hasLower { return true }
        if token.contains("_"), token.contains(where: \.isLetter) { return true }
        // Digits qualify a token only when it STARTS with a letter
        // (`gemma3`, `v2`). Leading-digit tokens are overwhelmingly
        // quantities and ordinals — `10am`, `3rd`, `4bit` — which would
        // otherwise promote after three dictations and burn slots in the
        // capped vocabulary the model is told to spell exactly.
        if token.contains(where: \.isNumber), let first = token.first, first.isLetter {
            return true
        }

        // Rule 3 — mid-sentence Capitalized word (Kamal, México).
        if !sentenceInitial, count >= 3, let first = token.first, first.isUppercase,
            token.dropFirst().allSatisfy({ $0.isLetter && $0.isLowercase }),
            !stoplist.contains(token)
        {
            return true
        }
        return false
    }
}

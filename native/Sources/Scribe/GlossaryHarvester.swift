import Foundation

/// Pure and stateless; the store owns counting, promotion, and decay.
enum GlossaryHarvester {
    /// Deduped per call, so the store's promotion threshold counts distinct dictations.
    static func candidates(in text: String) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
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

    /// Case-sensitive; used only by the mid-sentence rule.
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

        // Rule 1: acronyms, allowed even sentence-initial.
        if count <= 6, let first = token.first, first.isUppercase,
            token.allSatisfy({ ($0.isLetter && $0.isUppercase) || $0.isNumber })
        {
            return true
        }

        let hasLower = token.contains(where: \.isLowercase)
        if token.dropFirst().contains(where: \.isUppercase) && hasLower { return true }
        if token.contains("_"), token.contains(where: \.isLetter) { return true }
        // Leading-digit tokens (10am, 4bit) are quantities, so only letter-led tokens qualify.
        if token.contains(where: \.isNumber), let first = token.first, first.isLetter {
            return true
        }

        if !sentenceInitial, count >= 3, let first = token.first, first.isUppercase,
            token.dropFirst().allSatisfy({ $0.isLetter && $0.isLowercase }),
            !stoplist.contains(token)
        {
            return true
        }
        return false
    }
}

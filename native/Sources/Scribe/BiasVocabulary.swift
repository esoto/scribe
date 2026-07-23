import Foundation

/// One term to bias the recognizer toward, with the manglings that should
/// map to it. `text` is the canonical spelling; `aliases` are known STT
/// manglings (they feed the rescorer's string-similarity path).
struct BiasTerm: Equatable {
    let text: String
    let aliases: [String]
}

/// Builds the Parakeet bias vocabulary from the user's dictionary plus the
/// curated engineering pack. Pure and model-free — tokenization and CTC work
/// happen later, in `ParakeetEngine`.
///
/// Sourced from the FULL dictionary views (not the capped/deduped snapshot):
/// biasing should cover terms below the 30-term prompt cap, and a term that
/// is both a pair target and a learned word legitimately appears here even
/// though the Gemma snapshot forbids that overlap.
///
/// Deliberately does NOT consume `unmatchedHeardWords`: a bare unmatched word
/// has no canonical to attach to, and biasing the recognizer *toward* a
/// mangling would make it more likely to reproduce it. Manglings only enter
/// here once the user binds one — which creates a `ReplacementPair` whose
/// `original` becomes an alias below.
enum BiasVocabularyBuilder {
    /// Minimum canonical length the CTC spotter will accept.
    static let minTermLength = 3

    static func build(
        pairs: [ReplacementPair],
        glossary: [GlossaryEntry],
        includeCuratedPack: Bool
    ) -> [BiasTerm] {
        var order: [String] = []               // canonical keys, first-seen order
        var display: [String: String] = [:]    // key -> canonical text (first wins)
        var aliases: [String: [String]] = [:]

        func ensure(_ rawText: String) -> String? {
            guard let text = CleanupPrompt.sanitizeTerm(rawText), text.count >= minTermLength
            else { return nil }
            let key = text.lowercased()
            if display[key] == nil {
                display[key] = text
                aliases[key] = []
                order.append(key)
            }
            return key
        }

        func addAlias(_ key: String, _ rawAlias: String) {
            guard let alias = CleanupPrompt.sanitizeTerm(rawAlias) else { return }
            if alias.lowercased() == key { return }  // equal to canonical: adds nothing
            if !aliases[key]!.contains(where: { $0.lowercased() == alias.lowercased() }) {
                aliases[key]!.append(alias)
            }
        }

        // Replacement pairs: replacement is canonical, original is a mangling.
        for pair in pairs {
            guard let key = ensure(pair.replacement) else { continue }
            addAlias(key, pair.original)
        }

        // Learned glossary terms: canonical, no known mangling.
        for entry in glossary {
            _ = ensure(entry.term)
        }

        if includeCuratedPack {
            for term in EngineeringVocabulary.terms {
                _ = ensure(term)
            }
        }

        return order.map { BiasTerm(text: display[$0]!, aliases: aliases[$0]!) }
    }
}

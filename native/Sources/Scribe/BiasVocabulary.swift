import Foundation

/// `aliases` are known STT manglings; they feed the rescorer's similarity path.
struct BiasTerm: Equatable {
    let text: String
    let aliases: [String]
}

/// Pure and model-free. Ignores `unmatchedHeardWords`: biasing toward a mangling would make the
/// recognizer more likely to reproduce it, so manglings enter only once the user binds them.
enum BiasVocabularyBuilder {
    static let minTermLength = 3

    static func build(
        pairs: [ReplacementPair],
        glossary: [GlossaryEntry],
        includeCuratedPack: Bool
    ) -> [BiasTerm] {
        var order: [String] = []
        var display: [String: String] = [:]
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
            if alias.lowercased() == key { return }
            if !aliases[key]!.contains(where: { $0.lowercased() == alias.lowercased() }) {
                aliases[key]!.append(alias)
            }
        }

        for pair in pairs {
            guard let key = ensure(pair.replacement) else { continue }
            addAlias(key, pair.original)
        }

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

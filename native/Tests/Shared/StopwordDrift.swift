import Foundation

/// English share of stopword hits from `Gates`' own lists. Pure and shared, so the long-form
/// measurement and `ScribeTests` use one definition.
enum StopwordDrift {
    struct Hits: Equatable {
        let en: Int
        let es: Int
        /// 0 with no hits at all; print `en`/`es` beside it so "no stopwords" isn't read as "Spanish".
        var ratio: Double { en + es == 0 ? 0 : Double(en) / Double(en + es) }
    }

    /// Splits on non-letters because transcripts are punctuated and "the," must still count.
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Words in both lists ("a") are skipped so they can't pull a Spanish transcript toward 0.5.
    static func hits(_ words: [String]) -> Hits {
        Hits(
            en: words.filter { Gates.enStopwords.contains($0) && !Gates.esStopwords.contains($0) }.count,
            es: words.filter { Gates.esStopwords.contains($0) && !Gates.enStopwords.contains($0) }.count)
    }

    /// Drift starts partway through a long clip, and the whole-clip ratio stays under 0.5 until
    /// more than half of it has flipped, so each third is reported too.
    static func thirds(_ words: [String]) -> [Hits] {
        guard !words.isEmpty else { return [] }
        let size = (words.count + 2) / 3
        return stride(from: 0, to: words.count, by: size).map {
            hits(Array(words[$0..<min($0 + size, words.count)]))
        }
    }
}

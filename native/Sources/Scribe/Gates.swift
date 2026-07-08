import Foundation

/// Pure decision helpers for the dictation pipeline.
///
/// The energy gate is the primary defense against Whisper's silence
/// hallucination — verified 2026-07-07: mlx-whisper produced "Thank you." on
/// near-silence with no_speech_prob=0.0, so probability filters alone are not
/// enough.
enum Gates {
    static func rms(_ pcm: [Float]) -> Double {
        guard !pcm.isEmpty else { return 0.0 }
        let sumOfSquares = pcm.reduce(0.0) { acc, sample in
            acc + Double(sample) * Double(sample)
        }
        return (sumOfSquares / Double(pcm.count)).squareRoot()
    }

    static func passesEnergyGate(_ pcm: [Float], threshold: Double) -> Bool {
        guard !pcm.isEmpty else { return false }
        return rms(pcm) >= threshold
    }

    static func shouldClean(_ text: String, enabled: Bool, minWords: Int) -> Bool {
        return enabled && text.split(whereSeparator: { $0.isWhitespace }).count >= minWords
    }

    static func lengthOk(raw: String, cleaned: String, band: (Double, Double)) -> Bool {
        guard !raw.isEmpty, !cleaned.isEmpty else { return false }
        let ratio = Double(cleaned.count) / Double(raw.count)
        return band.0 <= ratio && ratio <= band.1
    }

    static func normalize(_ text: String) -> String {
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let enStopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "do", "does", "did",
        "to", "of", "on", "in", "at", "for", "with", "and", "or", "but", "this",
        "that", "it", "we", "you", "they", "should", "would", "could", "i",
    ]

    private static let esStopwords: Set<String> = [
        "el", "la", "los", "las", "un", "una", "es", "son", "está", "esta",
        "estaba", "ser", "hacer", "de", "en", "a", "para", "con", "y", "o",
        "pero", "este", "esto", "eso", "que", "se", "nosotros", "ustedes",
        "ellos", "debería", "yo", "según",
    ]

    /// Positive = English-leaning, negative = Spanish-leaning, 0 = neutral.
    private static func langScore(_ text: String) -> Int {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
        let enHits = words.filter { enStopwords.contains(String($0)) }.count
        let esHits = words.filter { esStopwords.contains(String($0)) }.count
        return enHits - esHits
    }

    /// Reject cleanups that flipped the language (small-model translation bug,
    /// observed 2026-07-07 with Gemma 3 4B on Spanglish input). Neutral or
    /// ambiguous scores pass — only a confident flip fails.
    static func languageConsistent(raw: String, cleaned: String) -> Bool {
        let rawScore = langScore(raw)
        let cleanedScore = langScore(cleaned)
        return !(rawScore * cleanedScore < 0 && abs(rawScore - cleanedScore) >= 3)
    }
}

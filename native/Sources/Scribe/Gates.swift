import Accelerate
import Foundation

/// Pure dictation-pipeline gates. The energy gate guards against Whisper's silence hallucinations.
enum Gates {
    static func rms(_ pcm: [Float]) -> Double {
        guard !pcm.isEmpty else { return 0.0 }
        // Accumulate in Double: a Float sum can flip borderline energy-gate decisions on long buffers.
        var doubles = [Double](repeating: 0, count: pcm.count)
        vDSP_vspdp(pcm, 1, &doubles, 1, vDSP_Length(pcm.count))
        var sumOfSquares = 0.0
        vDSP_svesqD(doubles, 1, &sumOfSquares, vDSP_Length(pcm.count))
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

    /// Internal so the model tests can measure language drift with the gate's own lists.
    static let enStopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "do", "does", "did",
        "to", "of", "on", "in", "at", "for", "with", "and", "or", "but", "this",
        "that", "it", "we", "you", "they", "should", "would", "could", "i",
    ]

    static let esStopwords: Set<String> = [
        "el", "la", "los", "las", "un", "una", "es", "son", "está", "esta",
        "estaba", "ser", "hacer", "de", "en", "a", "para", "con", "y", "o",
        "pero", "este", "esto", "eso", "que", "se", "nosotros", "ustedes",
        "ellos", "debería", "yo", "según",
    ]

    private static func langScore(_ text: String) -> Int {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace })
        let enHits = words.filter { enStopwords.contains(String($0)) }.count
        let esHits = words.filter { esStopwords.contains(String($0)) }.count
        return enHits - esHits
    }

    /// Rejects cleanups that flipped the language (small-model translation bug). Neutral scores pass.
    static func languageConsistent(raw: String, cleaned: String) -> Bool {
        let rawScore = langScore(raw)
        let cleanedScore = langScore(cleaned)
        return !(rawScore * cleanedScore < 0 && abs(rawScore - cleanedScore) >= 3)
    }
}

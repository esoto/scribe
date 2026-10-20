import Foundation

/// Pure helpers for Fix a Word: a dictation's raw transcript as clickable words, and the "heard as" phrase a
/// contiguous selection of them makes.
enum FixFromHistory {
    /// Whitespace-split tokens with edge punctuation removed — what the matcher compares. Punctuation-only tokens drop.
    static func words(in raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let core = token.trimmingCharacters(in: .punctuationCharacters)
            return core.isEmpty ? nil : core
        }
    }

    static func isContiguous(_ selected: Set<Int>) -> Bool {
        guard let lo = selected.min(), let hi = selected.max() else { return true }
        return selected.count == hi - lo + 1
    }

    /// nil unless the selection is non-empty, in range and contiguous: a pair matches a phrase, not scattered words.
    static func heardPhrase(words: [String], selected: Set<Int>) -> String? {
        guard let lo = selected.min(), let hi = selected.max(), lo >= 0, hi < words.count, isContiguous(selected)
        else { return nil }
        return words[lo...hi].joined(separator: " ")
    }

    /// A click toggles a word; one that would break the run restarts the selection at that word.
    static func toggling(_ index: Int, in selected: Set<Int>) -> Set<Int> {
        var next = selected
        if next.contains(index) {
            next.remove(index)
        } else {
            next.insert(index)
        }
        return isContiguous(next) ? next : [index]
    }

    /// A fix needs a phrase, a spelling that differs from it, and room in the dictionary.
    static func canFix(heard: String?, replacement: String, pairCount: Int) -> Bool {
        guard let heard, !atPairCap(pairCount) else { return false }
        let fix = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return !fix.isEmpty && fix.lowercased() != heard.lowercased()
    }
}

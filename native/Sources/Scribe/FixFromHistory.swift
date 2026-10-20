import Foundation

/// Pure helpers for Fix a Word: a dictation's raw transcript as clickable words, and the "heard as" phrase a
/// contiguous selection of them makes.
enum FixFromHistory {
    /// Split exactly as `TermReplacer.apply` splits (raw is already whitespace-normalised), so chip i is matcher token i.
    static func words(in raw: String) -> [String] {
        raw.split(separator: " ").map(String.init)
    }

    /// The token without the matcher's edge punctuation, or the token itself when nothing would be left.
    static func chipLabel(_ token: String) -> String {
        let core = TermReplacer.trimEdges(token)
        return core.isEmpty ? token : core
    }

    static func isContiguous(_ selected: Set<Int>) -> Bool {
        guard let lo = selected.min(), let hi = selected.max() else { return true }
        return selected.count == hi - lo + 1
    }

    /// nil unless the selection is non-empty, in range and contiguous. Only the outer ends lose punctuation: the
    /// matcher strips a window's ends, so "cuber, netties" must keep its comma to fire.
    static func heardPhrase(words: [String], selected: Set<Int>) -> String? {
        guard let lo = selected.min(), let hi = selected.max(), lo >= 0, hi < words.count, isContiguous(selected)
        else { return nil }
        let phrase = TermReplacer.trimEdges(words[lo...hi].joined(separator: " "))
        return phrase.isEmpty ? nil : phrase
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
        return !fix.isEmpty && fix != heard
    }
}

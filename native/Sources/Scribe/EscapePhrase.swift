import Foundation

/// "The words" before a command or break phrase dictates that phrase as text: "the words new line" pastes
/// `new line`. Turning voice commands off to type one phrase would also turn off every other, so the escape is
/// spoken instead. Only when the next words are a phrase, so "the words matter" stays as said. A break phrase is
/// escaped anywhere within a sentence; Return and undo only act on a whole utterance, so they are escaped only
/// when that is what was said, and "type the words enter in the box" keeps every word.
enum EscapePhrase {
    /// Folded like `VoiceCommand.fold`, English and Spanish side by side.
    static let phrases: [[String]] = [["the", "words"], ["las", "palabras"]]

    private static let breakPhrases = Set(BreakSplitter.phrases.keys)
    private static let commandPhrases = VoiceCommand.phraseTokens
    private static let longestFollower = breakPhrases.union(commandPhrases).map(\.count).max() ?? 1

    /// For each escape immediately followed by a phrase: the escape's token indices (`dropped`, never pasted) and
    /// the phrase's (`escaped`, never matched as a break). Longest phrase first, like `BreakSplitter`, so
    /// "new line break" is not left as an escaped "new line" plus a live "break".
    /// `sentenceEnds`: tokens that end in ".", "?" or "!" as heard. Inside an utterance, "the words." closes a
    /// sentence ("I can't find the words. New line.") rather than escaping the phrase after it.
    static func resolve(folded: [String], sentenceEnds: Set<Int> = []) -> (escaped: Set<Int>, dropped: Set<Int>) {
        var escaped = Set<Int>()
        var dropped = Set<Int>()
        var i = 0
        while i < folded.count {
            guard let escape = phrases.first(where: { matches($0, in: folded, at: i) }),
                !(sentenceEnds.contains(i + escape.count - 1) && !folded[..<i].allSatisfy(\.isEmpty)),
                let length = followerLength(in: folded, escapeAt: i, escapeLength: escape.count)
            else {
                i += 1
                continue
            }
            let phraseStart = i + escape.count
            dropped.formUnion(i..<phraseStart)
            escaped.formUnion(phraseStart..<(phraseStart + length))
            i = phraseStart + length
        }
        return (escaped, dropped)
    }

    private static func matches(_ escape: [String], in folded: [String], at i: Int) -> Bool {
        i + escape.count <= folded.count && Array(folded[i..<(i + escape.count)]) == escape
    }

    /// A command phrase counts only when the escape opens the utterance and the phrase closes it, which is when
    /// `VoiceCommand.match` would have fired. Empty tokens are punctuation on its own, which that match ignores.
    private static func followerLength(in folded: [String], escapeAt i: Int, escapeLength: Int) -> Int? {
        let start = i + escapeLength
        let opensUtterance = folded[..<i].allSatisfy(\.isEmpty)
        return stride(from: min(longestFollower, folded.count - start), through: 1, by: -1).first { length in
            let window = Array(folded[start..<(start + length)])
            if breakPhrases.contains(window) { return true }
            return opensUtterance && commandPhrases.contains(window)
                && folded[(start + length)...].allSatisfy(\.isEmpty)
        }
    }
}

import Foundation

/// "The words" before a command or break phrase dictates that phrase as text: "the words new line" pastes
/// `new line`. Turning voice commands off to type one phrase would also turn off every other, so the escape is
/// spoken instead. Only when the next words are a phrase, so "the words matter" stays as said.
enum EscapePhrase {
    /// Folded like `VoiceCommand.fold`, English and Spanish side by side.
    static let phrases: [[String]] = [["the", "words"], ["las", "palabras"]]

    /// Every phrase the escape can protect: the inline breaks, and the Return and undo commands that only act on a
    /// whole utterance, so "the words enter" pastes `enter` rather than pressing Return.
    private static let followers: Set<[String]> = Set(BreakSplitter.phrases.keys).union(VoiceCommand.phraseTokens)
    private static let longestFollower = followers.map(\.count).max() ?? 1

    /// For each escape immediately followed by a phrase: the escape's token indices (`dropped`, never pasted) and
    /// the phrase's (`escaped`, never matched as a break). Longest phrase first, like `BreakSplitter`, so
    /// "new line break" is not left as an escaped "new line" plus a live "break".
    static func resolve(folded: [String]) -> (escaped: Set<Int>, dropped: Set<Int>) {
        var escaped = Set<Int>()
        var dropped = Set<Int>()
        var i = 0
        while i < folded.count {
            guard let escape = phrases.first(where: { matches($0, in: folded, at: i) }),
                let length = followerLength(in: folded, at: i + escape.count)
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

    private static func followerLength(in folded: [String], at start: Int) -> Int? {
        stride(from: min(longestFollower, folded.count - start), through: 1, by: -1)
            .first { followers.contains(Array(folded[start..<(start + $0)])) }
    }
}

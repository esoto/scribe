import XCTest

final class FixFromHistoryTests: XCTestCase {
    func testWordsAreTheMatchersTokens() {
        XCTAssertEqual(
            FixFromHistory.words(in: "so, deploy to headsner. — tonight!"),
            ["so,", "deploy", "to", "headsner.", "—", "tonight!"])
        XCTAssertEqual(FixFromHistory.chipLabel("\u{201C}camel\u{201D}"), "camel")
        XCTAssertEqual(FixFromHistory.chipLabel("?"), "?")
        XCTAssertEqual(FixFromHistory.words(in: ""), [])
    }

    func testEveryPickedRunIsWhatTheMatcherReplaces() {
        let dictations = [
            "deploy with cuber, netties tonight", "deploy with cuber — netties tonight", "¿headsner? sí",
            "we hit 50% on headsner", "ship it to headsner— then rest", "so, deploy to headsner. — tonight!",
            "I think ... we should", "wait ... ? no",
        ]
        for raw in dictations {
            let words = FixFromHistory.words(in: raw)
            for lo in words.indices {
                for hi in lo..<min(words.count, lo + 3) {
                    guard let heard = FixFromHistory.heardPhrase(words: words, selected: Set(lo...hi)) else { continue }
                    let pair = ReplacementPair(original: heard, replacement: "XX", addedAt: Date())
                    XCTAssertNotEqual(TermReplacer.apply([pair], to: raw), raw, "\(raw) — picked \(heard)")
                }
            }
        }
    }

    func testHeardPhraseNeedsAContiguousSelection() {
        let words = ["deploy", "with", "cuber", "netties", "tonight"]
        XCTAssertEqual(FixFromHistory.heardPhrase(words: words, selected: [2]), "cuber")
        XCTAssertEqual(FixFromHistory.heardPhrase(words: words, selected: [2, 3]), "cuber netties")
        XCTAssertNil(FixFromHistory.heardPhrase(words: words, selected: [0, 2]))
        XCTAssertNil(FixFromHistory.heardPhrase(words: words, selected: []))
        XCTAssertNil(FixFromHistory.heardPhrase(words: words, selected: [5]))
        XCTAssertNil(FixFromHistory.heardPhrase(words: words, selected: [-1]))
        XCTAssertEqual(FixFromHistory.heardPhrase(words: ["with", "cuber,", "netties."], selected: [1, 2]), "cuber, netties")
        XCTAssertNil(FixFromHistory.heardPhrase(words: ["?"], selected: [0]))
        XCTAssertEqual(FixFromHistory.heardPhrase(words: ["think", "..."], selected: [0, 1]), "think")
        XCTAssertNil(FixFromHistory.heardPhrase(words: ["...", "?"], selected: [0, 1]))
    }

    func testTogglingExtendsOrRestartsTheRun() {
        XCTAssertEqual(FixFromHistory.toggling(2, in: []), [2])
        XCTAssertEqual(FixFromHistory.toggling(3, in: [2]), [2, 3])
        XCTAssertEqual(FixFromHistory.toggling(1, in: [2, 3]), [1, 2, 3])
        // Removing an end shortens the run; removing the middle would split it, so the click restarts there.
        XCTAssertEqual(FixFromHistory.toggling(3, in: [1, 2, 3]), [1, 2])
        XCTAssertEqual(FixFromHistory.toggling(2, in: [1, 2, 3]), [2])
        // A far-away word restarts the selection.
        XCTAssertEqual(FixFromHistory.toggling(7, in: [1, 2]), [7])
        XCTAssertEqual(FixFromHistory.toggling(2, in: [2]), [])
    }

    func testCanFixNeedsAPhraseADifferentSpellingAndRoom() {
        XCTAssertTrue(FixFromHistory.canFix(heard: "headsner", replacement: "Hetzner", pairCount: 0))
        XCTAssertFalse(FixFromHistory.canFix(heard: nil, replacement: "Hetzner", pairCount: 0))
        XCTAssertFalse(FixFromHistory.canFix(heard: "headsner", replacement: "   ", pairCount: 0))
        XCTAssertTrue(FixFromHistory.canFix(heard: "github", replacement: "GitHub", pairCount: 0))
        XCTAssertFalse(FixFromHistory.canFix(heard: "Hetzner", replacement: " Hetzner ", pairCount: 0))
        XCTAssertFalse(
            FixFromHistory.canFix(heard: "headsner", replacement: "Hetzner", pairCount: UserDictionaryStore.maxStoredPairs))
        XCTAssertTrue(
            FixFromHistory.canFix(heard: "headsner", replacement: "Hetzner", pairCount: UserDictionaryStore.maxStoredPairs - 1))
    }
}

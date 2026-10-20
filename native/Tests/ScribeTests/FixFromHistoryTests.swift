import XCTest

final class FixFromHistoryTests: XCTestCase {
    func testWordsDropEdgePunctuationAndEmptyTokens() {
        XCTAssertEqual(
            FixFromHistory.words(in: "so, deploy to headsner. — tonight!"),
            ["so", "deploy", "to", "headsner", "tonight"])
        XCTAssertEqual(FixFromHistory.words(in: "\u{201C}camel\u{201D} is ready"), ["camel", "is", "ready"])
        XCTAssertEqual(FixFromHistory.words(in: ""), [])
    }

    func testHeardPhraseNeedsAContiguousSelection() {
        let words = ["deploy", "with", "cuber", "netties", "tonight"]
        XCTAssertEqual(FixFromHistory.heardPhrase(words: words, selected: [2]), "cuber")
        XCTAssertEqual(FixFromHistory.heardPhrase(words: words, selected: [2, 3]), "cuber netties")
        XCTAssertNil(FixFromHistory.heardPhrase(words: words, selected: [0, 2]))
        XCTAssertNil(FixFromHistory.heardPhrase(words: words, selected: []))
        XCTAssertNil(FixFromHistory.heardPhrase(words: words, selected: [5]))
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
    }

    func testCanFixNeedsAPhraseADifferentSpellingAndRoom() {
        XCTAssertTrue(FixFromHistory.canFix(heard: "headsner", replacement: "Hetzner", pairCount: 0))
        XCTAssertFalse(FixFromHistory.canFix(heard: nil, replacement: "Hetzner", pairCount: 0))
        XCTAssertFalse(FixFromHistory.canFix(heard: "headsner", replacement: "   ", pairCount: 0))
        XCTAssertFalse(FixFromHistory.canFix(heard: "hetzner", replacement: "Hetzner", pairCount: 0))
        XCTAssertFalse(
            FixFromHistory.canFix(heard: "headsner", replacement: "Hetzner", pairCount: UserDictionaryStore.maxStoredPairs))
    }
}

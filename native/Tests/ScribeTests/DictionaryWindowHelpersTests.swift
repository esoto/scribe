import XCTest

final class DictionaryWindowHelpersTests: XCTestCase {
    func testPairRowLabel() {
        XCTAssertEqual(pairRowLabel("camel", "kamal"), "camel → kamal")
        let long = String(repeating: "a", count: 40)
        XCTAssertEqual(
            pairRowLabel(long, "b"),
            String(repeating: "a", count: 23) + "… → b")
    }

    func testCanAddPair() {
        XCTAssertTrue(canAddPair(original: "camel", replacement: "kamal"))
        XCTAssertFalse(canAddPair(original: "   ", replacement: "kamal"))
        XCTAssertFalse(canAddPair(original: "camel", replacement: ""))
        XCTAssertFalse(canAddPair(original: "\n\t ", replacement: "kamal"))
    }

    func testCanAddPairAllowsLongAndMarkupReplacements() {
        // Pairs are pasted verbatim, never sent to the model, so neither the
        // prompt length cap nor the markup stripping applies to them.
        let long = String(repeating: "a", count: 200)
        XCTAssertTrue(canAddPair(original: "acme", replacement: long))
        XCTAssertTrue(canAddPair(original: "div tag", replacement: "<div>"))
        XCTAssertTrue(canAddPair(original: "quote", replacement: "\""))
    }

    func testMenuGlossaryTermsExcludesSeededAndRanksByUse() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = [
            GlossaryEntry(term: "Rare", count: 3, firstSeen: now, lastSeen: now),
            GlossaryEntry(term: "Common", count: 40, firstSeen: now, lastSeen: now),
            GlossaryEntry(term: "Middle", count: 9, firstSeen: now, lastSeen: now),
        ]
        XCTAssertEqual(menuGlossaryTerms(entries), ["Common", "Middle", "Rare"])
        XCTAssertEqual(menuGlossaryTerms(entries, limit: 2), ["Common", "Middle"])
        // Learned entries only — a pair's seeded vocabulary never appears
        // here, because the menu's Remove could not honor it.
        XCTAssertEqual(menuGlossaryTerms([]), [])
    }

    func testDistinctReplacementTargets() {
        let at = Date(timeIntervalSince1970: 0)
        let pairs = [
            ReplacementPair(original: "camel", replacement: "kamal", addedAt: at),
            ReplacementPair(original: "camal", replacement: "kamal", addedAt: at),
            ReplacementPair(original: "headstar", replacement: "hetzner", addedAt: at),
            ReplacementPair(original: "hatsner", replacement: "Hetzner", addedAt: at),
        ]
        // Several manglings share one target, so the bind menu offers each
        // target once — case-insensitively deduped.
        XCTAssertEqual(distinctReplacementTargets(pairs), ["hetzner", "kamal"])
        XCTAssertEqual(distinctReplacementTargets([]), [])
    }

    func testGlossaryRowDetail() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            glossaryRowDetail(count: 3, lastSeen: now, now: now), "seen 3× · today")
        XCTAssertEqual(
            glossaryRowDetail(count: 5, lastSeen: now.addingTimeInterval(-86_400), now: now),
            "seen 5× · yesterday")
        XCTAssertEqual(
            glossaryRowDetail(count: 12, lastSeen: now.addingTimeInterval(-3 * 86_400), now: now),
            "seen 12× · 3 days ago")
    }
}

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
        XCTAssertFalse(canAddPair(original: "<>\"", replacement: "kamal"))
    }

    func testCanAddPairRejectsInputTheModelWouldOnlySeePartOf() {
        // The prompt caps a term at 48 chars. Accepting a longer one would
        // save what the user typed but apply a fragment, with nothing on
        // screen showing the difference.
        let atLimit = String(repeating: "a", count: CleanupPrompt.maxTermLength)
        let overLimit = atLimit + "b"
        XCTAssertTrue(canAddPair(original: "acme", replacement: atLimit))
        XCTAssertFalse(canAddPair(original: "acme", replacement: overLimit))
        XCTAssertFalse(canAddPair(original: overLimit, replacement: "acme"))
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

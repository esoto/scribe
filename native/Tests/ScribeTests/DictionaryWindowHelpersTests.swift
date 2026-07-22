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

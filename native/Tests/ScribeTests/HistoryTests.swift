import XCTest

final class HistoryTests: XCTestCase {
    private func rec(_ i: Int) -> DictationRecord {
        DictationRecord(
            raw: "r\(i)",
            final: "f\(i)",
            engine: "parakeet",
            cleaned: true,
            at: Date(timeIntervalSince1970: Double(i)),
            durationMs: 10
        )
    }

    func testNewestFirstAndBounded() {
        let h = History(maxLen: 3)
        for i in 0..<5 {
            h.append(rec(i))
        }
        XCTAssertEqual(h.items().map { $0.raw }, ["r4", "r3", "r2"])
    }

    func testEmpty() {
        XCTAssertEqual(History(maxLen: 3).items().count, 0)
    }

    func testSetMaxLenShrinksToNewest() {
        let h = History(maxLen: 10)
        for i in 0..<5 {
            h.append(rec(i))
        }
        h.setMaxLen(3)
        XCTAssertEqual(h.items().map { $0.raw }, ["r4", "r3", "r2"])
    }

    func testSetMaxLenClampsToOne() {
        let h = History(maxLen: 10)
        for i in 0..<5 {
            h.append(rec(i))
        }
        h.setMaxLen(0)
        XCTAssertEqual(h.items().map { $0.raw }, ["r4"])
    }

    func testSetMaxLenGrowKeepsStored() {
        let h = History(maxLen: 2)
        for i in 0..<2 {
            h.append(rec(i))
        }
        h.setMaxLen(5)
        XCTAssertEqual(h.items().map { $0.raw }, ["r1", "r0"])
    }
}

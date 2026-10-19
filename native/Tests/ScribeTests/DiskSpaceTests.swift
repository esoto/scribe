import XCTest

final class DiskSpaceTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    func testDownloadThatFitsIsNotBlocked() {
        XCTAssertNil(DiskSpace.shortfallMessage(label: "Gemma", needed: 2 * gb, available: 10 * gb))
    }

    func testExactlyTheMarginAboveTheNeedStillFits() {
        let needed = 2 * gb
        XCTAssertNil(DiskSpace.shortfallMessage(label: "Gemma", needed: needed, available: needed + DiskSpace.margin))
    }

    func testOneByteUnderTheMarginIsRefused() {
        let needed = 2 * gb
        XCTAssertNotNil(DiskSpace.shortfallMessage(label: "Gemma", needed: needed, available: needed + DiskSpace.margin - 1))
    }

    /// Inside the margin the download alone would fit, so "needs" must include the headroom or the numbers contradict.
    func testTheMessageNamesTheFreeSpaceTheCheckRequires() {
        XCTAssertEqual(
            DiskSpace.shortfallMessage(label: "Gemma", needed: 2 * gb, available: 2_200_000_000),
            "Not enough free disk space — Gemma needs 2.5 GB, 2.2 GB free.")
    }

    func testUnknownFreeSpaceNeverBlocks() {
        XCTAssertNil(DiskSpace.shortfallMessage(label: "Gemma", needed: 2 * gb, available: nil))
    }

    func testAvailableReadsTheVolumeOfAnExistingDirectory() {
        XCTAssertGreaterThan(DiskSpace.available(at: URL(fileURLWithPath: NSTemporaryDirectory())) ?? 0, 0)
    }

    /// The models folder doesn't exist until the first download; "unknown" there would skip the check exactly when it matters.
    func testAvailableFallsBackToTheNearestExistingAncestor() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-\(UUID().uuidString)/models", isDirectory: true)
        XCTAssertGreaterThan(DiskSpace.available(at: missing) ?? 0, 0)
    }
}

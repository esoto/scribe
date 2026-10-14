import XCTest

final class ModelsWindowHelpersTests: XCTestCase {
    func testFormatBytes() {
        XCTAssertEqual(formatBytes(2_800_000_000), "2.8 GB")
        XCTAssertEqual(formatBytes(450_000_000), "450 MB")
        XCTAssertEqual(formatBytes(0), "0 MB")
    }

    func testCanDeleteModel() {
        XCTAssertFalse(canDeleteModel(.gemma3, active: "gemma3", pending: nil), "in use")
        XCTAssertFalse(canDeleteModel(.gemma4, active: "gemma3", pending: "gemma4"), "being switched to")
        XCTAssertFalse(canDeleteModel(.appleIntelligence, active: "gemma3", pending: nil), "nothing on disk")
        XCTAssertTrue(canDeleteModel(.gemma4, active: "gemma3", pending: nil))
    }

    func testRows() {
        let rows = modelRows(
            statuses: [.gemma3: .downloaded(bytes: 2_800_000_000), .gemma4: .partial(bytes: 1_200_000_000)],
            active: "gemma3", pending: nil, appleIntelligenceReason: nil)
        XCTAssertEqual(rows.map(\.id), [.gemma3, .gemma4, .gemma4e2b, .appleIntelligence])
        XCTAssertEqual(rows[0].detail, "In use · 2.8 GB")
        XCTAssertFalse(rows[0].canDelete)
        XCTAssertFalse(rows[0].canUse)
        XCTAssertEqual(rows[1].detail, "Incomplete download · 1.2 GB")
        XCTAssertTrue(rows[1].canDelete)
        XCTAssertTrue(rows[1].canUse)
        XCTAssertEqual(rows[3].detail, "Built into macOS · no download")
        XCTAssertTrue(rows[3].canUse)
        XCTAssertFalse(rows[3].canDelete)
    }

    func testNotDownloadedRowShowsApproxSize() {
        let rows = modelRows(statuses: [:], active: "gemma3", pending: nil, appleIntelligenceReason: nil)
        XCTAssertEqual(rows[1].detail, "Not downloaded · ~4.9 GB")
        XCTAssertFalse(rows[1].canDelete)
    }

    func testUnavailableAppleIntelligenceShowsReasonAndCantBeUsed() {
        let rows = modelRows(statuses: [:], active: "gemma3", pending: nil, appleIntelligenceReason: "Turn on Apple Intelligence in System Settings")
        XCTAssertEqual(rows[3].detail, "Turn on Apple Intelligence in System Settings")
        XCTAssertFalse(rows[3].canUse)
    }

    func testPickerLabel() {
        XCTAssertEqual(pickerLabel(CleanupModelCatalog.gemma3, status: .downloaded(bytes: 1)), "Gemma 3 4B")
        XCTAssertEqual(pickerLabel(CleanupModelCatalog.gemma4, status: .notDownloaded), "Gemma 4 E4B — 4.9 GB download")
        XCTAssertEqual(pickerLabel(CleanupModelCatalog.appleIntelligence, status: .notDownloaded), "Apple Intelligence (fastest, less accurate)")
    }

    func testLearningNote() {
        XCTAssertNil(learningNote(fidelitySafe: true, learningOn: true))
        XCTAssertNil(learningNote(fidelitySafe: false, learningOn: false))
        XCTAssertEqual(learningNote(fidelitySafe: false, learningOn: true), "Learned terms aren't sent to this model — it can drop words")
    }

    func testDeleteConfirmationTitle() {
        let row = modelRows(statuses: [.gemma4: .downloaded(bytes: 4_900_000_000)], active: "gemma3", pending: nil, appleIntelligenceReason: nil)[1]
        XCTAssertEqual(deleteConfirmationTitle(row), "Delete Gemma 4 E4B (4.9 GB)?")
        XCTAssertEqual(deleteConfirmationTitle(nil), "")
    }
}

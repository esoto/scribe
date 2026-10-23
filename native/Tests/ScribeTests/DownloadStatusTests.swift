import Combine
import XCTest

@MainActor
final class DownloadStatusTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    /// Counts `objectWillChange` emissions, i.e. the glyph, menu and Setup rebuilds a write would cause.
    private func countPublishes(_ downloads: DownloadStatus) -> () -> Int {
        var count = 0
        downloads.objectWillChange.sink { count += 1 }.store(in: &cancellables)
        return { count }
    }

    func testStartsEmpty() {
        let downloads = DownloadStatus()

        XCTAssertNil(downloads.sttStatus)
        XCTAssertNil(downloads.sttFraction)
        XCTAssertNil(downloads.enhancerStatus)
    }

    // MARK: - Speech model

    func testSttProgressSetsTheStatusLineAndTheGlyphFraction() {
        let downloads = DownloadStatus()

        downloads.report(stt: "Parakeet Ultra", fraction: 0.427)

        XCTAssertEqual(downloads.sttStatus, "Downloading Parakeet Ultra… 42%")
        XCTAssertEqual(downloads.sttFraction ?? -1, 0.427, accuracy: 1e-9)
    }

    func testSttProgressWithinTheSameWholePercentPublishesNothing() {
        let downloads = DownloadStatus()
        downloads.report(stt: "Parakeet Ultra", fraction: 0.421)
        let publishes = countPublishes(downloads)

        // FluidAudio reports every received chunk; neither the status line nor the glyph moves between percents.
        downloads.report(stt: "Parakeet Ultra", fraction: 0.425)
        downloads.report(stt: "Parakeet Ultra", fraction: 0.429)

        XCTAssertEqual(publishes(), 0)
        XCTAssertEqual(downloads.sttStatus, "Downloading Parakeet Ultra… 42%")
        XCTAssertEqual(downloads.sttFraction ?? -1, 0.421, accuracy: 1e-9)
    }

    func testSttProgressPublishesAgainWhenTheWholePercentChanges() {
        let downloads = DownloadStatus()
        downloads.report(stt: "Parakeet Ultra", fraction: 0.421)
        let publishes = countPublishes(downloads)

        downloads.report(stt: "Parakeet Ultra", fraction: 0.431)

        XCTAssertGreaterThan(publishes(), 0)
        XCTAssertEqual(downloads.sttStatus, "Downloading Parakeet Ultra… 43%")
        XCTAssertEqual(downloads.sttFraction ?? -1, 0.431, accuracy: 1e-9)
    }

    func testSttCompletionClearsBothValues() {
        let downloads = DownloadStatus()
        downloads.report(stt: "Parakeet Ultra", fraction: 0.99)

        downloads.report(stt: "Parakeet Ultra", fraction: 1.0)

        XCTAssertNil(downloads.sttStatus)
        XCTAssertNil(downloads.sttFraction)
    }

    func testSttReportOfAnAlreadyFinishedDownloadPublishesNothing() {
        let downloads = DownloadStatus()
        let publishes = countPublishes(downloads)

        // A model that is already on disk can still report 100 %; the menu must not rebuild for it.
        downloads.report(stt: "Parakeet Ultra", fraction: 1.0)
        downloads.report(stt: "Parakeet Ultra", fraction: 1.0)

        XCTAssertEqual(publishes(), 0)
        XCTAssertNil(downloads.sttStatus)
        XCTAssertNil(downloads.sttFraction)
    }

    func testSttDownloadCanStartAgainAfterCompleting() {
        let downloads = DownloadStatus()
        downloads.report(stt: "Parakeet Ultra", fraction: 1.0)

        downloads.report(stt: "Parakeet Ultra", fraction: 0.0)

        XCTAssertEqual(downloads.sttStatus, "Downloading Parakeet Ultra… 0%")
        XCTAssertEqual(downloads.sttFraction, 0.0)
    }

    // MARK: - Enhance Audio model

    func testEnhancerProgressSetsTheStatusLine() {
        let downloads = DownloadStatus()

        downloads.report(enhancer: "Enhance Audio", fraction: 0.05)

        XCTAssertEqual(downloads.enhancerStatus, "Downloading Enhance Audio… 5%")
    }

    func testEnhancerProgressWithinTheSameWholePercentPublishesNothing() {
        let downloads = DownloadStatus()
        downloads.report(enhancer: "Enhance Audio", fraction: 0.051)
        let publishes = countPublishes(downloads)

        downloads.report(enhancer: "Enhance Audio", fraction: 0.055)
        downloads.report(enhancer: "Enhance Audio", fraction: 0.059)

        XCTAssertEqual(publishes(), 0)
        XCTAssertEqual(downloads.enhancerStatus, "Downloading Enhance Audio… 5%")
    }

    func testEnhancerCompletionClearsTheStatusAndThenPublishesNothing() {
        let downloads = DownloadStatus()
        downloads.report(enhancer: "Enhance Audio", fraction: 0.5)

        downloads.report(enhancer: "Enhance Audio", fraction: 1.0)
        XCTAssertNil(downloads.enhancerStatus)

        let publishes = countPublishes(downloads)
        downloads.report(enhancer: "Enhance Audio", fraction: 1.0)
        XCTAssertEqual(publishes(), 0)
    }

    // MARK: - Whole-percent rule

    func testNothingPublishedYetCountsAsAChange() {
        XCTAssertTrue(DownloadStatus.wholePercentChanged(from: nil, to: 0.0))
        XCTAssertTrue(DownloadStatus.wholePercentChanged(from: nil, to: 0.5))
    }

    func testWithinOneWholePercentIsNotAChange() {
        XCTAssertFalse(DownloadStatus.wholePercentChanged(from: 0.421, to: 0.429))
        XCTAssertFalse(DownloadStatus.wholePercentChanged(from: 0.421, to: 0.421))
    }

    func testCrossingAWholePercentIsAChangeInEitherDirection() {
        XCTAssertTrue(DownloadStatus.wholePercentChanged(from: 0.429, to: 0.431))
        XCTAssertTrue(DownloadStatus.wholePercentChanged(from: 0.9, to: 0.1), "a retried download starts over")
    }

    func testCompletionIsAChangeFromTheLastPercentAndRepeatsAreNot() {
        XCTAssertTrue(DownloadStatus.wholePercentChanged(from: 0.999, to: 1.0))
        XCTAssertFalse(DownloadStatus.wholePercentChanged(from: 1.0, to: 1.0))
    }

    func testTheStatusTextAndTheGateShareOneDefinitionOfAWholePercent() {
        // Half a percent in, so no value sits on a floating-point boundary.
        for percent in 0..<100 {
            let fraction = (Double(percent) + 0.5) / 100
            XCTAssertEqual(DownloadStatus.wholePercent(fraction), percent)
            XCTAssertEqual(
                CleanupModelCatalog.statusText(label: "Model", fraction: fraction), "Downloading Model… \(percent)%")
        }
    }

    // MARK: - Independence

    func testTheTwoDownloadsDoNotTouchEachOther() {
        let downloads = DownloadStatus()

        downloads.report(stt: "Parakeet Ultra", fraction: 0.3)
        downloads.report(enhancer: "Enhance Audio", fraction: 0.6)
        XCTAssertEqual(downloads.sttStatus, "Downloading Parakeet Ultra… 30%")
        XCTAssertEqual(downloads.enhancerStatus, "Downloading Enhance Audio… 60%")

        downloads.report(stt: "Parakeet Ultra", fraction: 1.0)
        XCTAssertNil(downloads.sttStatus)
        XCTAssertEqual(downloads.enhancerStatus, "Downloading Enhance Audio… 60%")

        downloads.report(enhancer: "Enhance Audio", fraction: 1.0)
        XCTAssertNil(downloads.enhancerStatus)
    }
}

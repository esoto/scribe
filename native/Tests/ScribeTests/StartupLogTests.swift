import XCTest

/// "models ready" was logged even when the preload had thrown, so the log said the opposite of what happened.
final class StartupLogTests: XCTestCase {
    func testReadyLineWhenEverythingLoaded() {
        XCTAssertEqual(
            AppModel.startupLogLine(sttLoaded: true, cleanupLoaded: true, elapsed: 3.14),
            "models ready in 3.1s")
    }

    func testFailedTranscriptionModelIsNamedAndNeverReportedReady() {
        let line = AppModel.startupLogLine(sttLoaded: false, cleanupLoaded: true, elapsed: 2.0)
        XCTAssertFalse(line.contains("models ready"), line)
        XCTAssertTrue(line.contains("transcription model failed to load"), line)
    }

    func testFailedCleanupModelIsNamed() {
        let line = AppModel.startupLogLine(sttLoaded: true, cleanupLoaded: false, elapsed: 2.0)
        XCTAssertFalse(line.contains("models ready"), line)
        XCTAssertTrue(line.contains("cleanup model failed to load"), line)
    }

    func testBothFailuresAreNamed() {
        let line = AppModel.startupLogLine(sttLoaded: false, cleanupLoaded: false, elapsed: 2.0)
        XCTAssertTrue(line.contains("transcription model and cleanup model failed to load"), line)
    }
}

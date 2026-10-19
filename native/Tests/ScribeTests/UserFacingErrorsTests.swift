import XCTest

final class UserFacingErrorsTests: XCTestCase {
    private let offlineNotice =
        "Transcription failed — the speech model couldn't be downloaded. Audio saved; try again online."
    private let missingNotice =
        "Transcription failed — the speech model is missing. Audio saved; delete the models folder to re-download."
    private let logNotice = "Transcription failed — audio saved. Open Setup / Doctor › Show Log in Finder for the cause."

    func testConnectivityFailuresPointAtTheDownload() {
        for message in ["device is offline", "network timed out", "download aborted", "URLError: -1009", "no internet connection"] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), offlineNotice, message)
        }
    }

    func testMissingModelFilesPointAtTheModelsFolder() {
        for message in ["No such file or directory", "model not found", "weights missing"] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), missingNotice, message)
        }
    }

    func testOtherFailuresPointAtTheLog() {
        for message in ["out of memory", "decode failed", ""] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), logNotice, message)
        }
    }

    func testRecordingNoticeIsTheFixedMicrophoneHintAndNeverEchoesTheError() {
        let notice = UserFacingError.recordingNotice(error: "AVAudioEngine error -10868")
        XCTAssertEqual(notice, "Couldn't start recording — check the microphone in Settings › Audio.")
        XCTAssertFalse(notice.contains("-10868"))
    }
}

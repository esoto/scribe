import XCTest

final class UserFacingErrorsTests: XCTestCase {
    private let offlineNotice =
        "Transcription failed — the speech model couldn't be downloaded. Audio saved; try again online."
    private let missingNotice =
        "Transcription failed — the speech model is missing. Audio saved; delete the models folder to re-download."
    private let logNotice = "Transcription failed — audio saved. Open Setup / Doctor › Show Log in Finder for the cause."
    private let diskNotice = "Not enough free disk space for the speech model — free some space and relaunch; audio saved"

    func testConnectivityFailuresPointAtTheDownload() {
        for message in ["device is offline", "network timed out", "download aborted", "URLError: -1009", "no internet connection"] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), offlineNotice, message)
        }
    }

    func testMissingModelFilesPointAtTheModelsFolder() {
        for message in ["No such file or directory", "Model file not found at /x/AudioEncoder.mlmodelc", "weights missing"] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), missingNotice, message)
        }
    }

    /// WhisperKit wraps every Hub failure as "Model not found. …", including on a model already on disk.
    func testWhisperKitHubFailuresAreNotAMissingModel() {
        let wrapper = "modelsUnavailable(\"Model not found. Please check the model or repo name and try again. Error: "
        XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: wrapper + "httpStatusCode(503))"), logNotice)
        XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: wrapper + "authorizationRequired)"), logNotice)
        XCTAssertEqual(
            UserFacingError.transcriptionNotice(
                engineMessage: wrapper + "downloadError(\"The Internet connection appears to be offline.\"))"),
            offlineNotice)
    }

    func testOtherFailuresPointAtTheLog() {
        for message in ["out of memory", "decode failed", ""] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), logNotice, message)
        }
    }

    func testOutOfDiskMessagesNameTheFreeSpace() {
        for message in ["No space left on device", "no space left on device", "write failed: ENOSPC", "enospc"] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), diskNotice, message)
        }
    }

    /// A download that fails for lack of disk is a disk problem; "try again online" would point at the wrong fix.
    func testOutOfDiskWinsOverTheOtherBranches() {
        for message in [
            "No such file or directory: No space left on device",
            "download failed: ENOSPC",
            #"downloadFailed(path: "a", underlying: Error Domain=NSCocoaErrorDomain Code=640 "The file couldn’t be saved because there isn’t enough space.")"#,
        ] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), diskNotice, message)
        }
    }

    func testDiskWordingThatIsNotOutOfSpaceKeepsTheLogNotice() {
        for message in ["Disk I/O error", "no space for the window"] {
            XCTAssertEqual(UserFacingError.transcriptionNotice(engineMessage: message), logNotice, message)
        }
    }

    func testRecordingNoticeIsTheFixedMicrophoneHintAndNeverEchoesTheError() {
        let notice = UserFacingError.recordingNotice(error: "AVAudioEngine error -10868")
        XCTAssertEqual(notice, "Couldn't start recording — check the microphone in Settings › Audio.")
        XCTAssertFalse(notice.contains("-10868"))
    }
}

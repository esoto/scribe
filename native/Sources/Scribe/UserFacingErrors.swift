import Foundation

/// Notices name the next step; the raw engine text goes to scribe.log only (it can echo paths or model ids).
enum UserFacingError {
    static func transcriptionNotice(engineMessage: String) -> String {
        let m = engineMessage.lowercased()
        if m.contains("offline") || m.contains("network") || m.contains("download") || m.contains("urlerror")
            || m.contains("internet")
        {
            return "Transcription failed — the speech model couldn't be downloaded. Audio saved; try again online."
        }
        // "file not found", not "not found": WhisperKit reports every Hub failure (5xx, 429, auth) as "Model not found…",
        // even for a model already on disk, and deleting the models folder is the wrong step then.
        if m.contains("no such file") || m.contains("file not found") || m.contains("missing") {
            return "Transcription failed — the speech model is missing. Audio saved; delete the models folder to re-download."
        }
        return "Transcription failed — audio saved. Open Setup / Doctor › Show Log in Finder for the cause."
    }

    static func recordingNotice(error: String) -> String {
        "Couldn't start recording — check the microphone in Settings › Audio."
    }
}

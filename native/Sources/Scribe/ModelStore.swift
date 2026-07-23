import Foundation

/// Single app-managed home for every model scribe downloads, instead of
/// three framework-default caches scattered across the disk. Deleting
/// `~/Library/Application Support/scribe/models` resets everything; each
/// loader re-downloads into its slot on next use.
///
/// See docs/superpowers/specs/2026-07-09-model-store-and-custom-cleanup-model-design.md.
enum ModelStore {
    static let baseDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/scribe/models", isDirectory: true)

    /// HubCache root for the cleanup model — Python-compatible HF hub
    /// layout (`models--<org>--<repo>/…`) inside.
    static var gemmaDirectory: URL {
        baseDirectory.appendingPathComponent("gemma", isDirectory: true)
    }

    /// FluidAudio target directory. The leaf keeps the repo folder name —
    /// FluidAudio infers the model version from the path.
    static var parakeetDirectory: URL {
        baseDirectory.appendingPathComponent(
            "parakeet/parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    /// WhisperKit `downloadBase` — WhisperKit creates
    /// `models/argmaxinc/whisperkit-coreml/<model>` inside it.
    static var whisperDirectory: URL {
        baseDirectory.appendingPathComponent("whisper", isDirectory: true)
    }

    /// FluidAudio CTC keyword-spotter model, used only for Parakeet
    /// vocabulary biasing — a separate download from the TDT model above.
    /// The leaf keeps the repo folder name so FluidAudio's path-based
    /// variant inference stays consistent.
    static var ctcDirectory: URL {
        baseDirectory.appendingPathComponent(
            "ctc/parakeet-ctc-110m-coreml", isDirectory: true)
    }
}

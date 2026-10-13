import Foundation

/// Single app-managed home for downloaded models. Deleting it resets all of them.
enum ModelStore {
    static let baseDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/scribe/models", isDirectory: true)

    static var gemmaDirectory: URL {
        baseDirectory.appendingPathComponent("gemma", isDirectory: true)
    }

    /// FluidAudio infers the model version from this path, so keep the repo folder name.
    static var parakeetDirectory: URL {
        baseDirectory.appendingPathComponent(
            "parakeet/parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    static var whisperDirectory: URL {
        baseDirectory.appendingPathComponent("whisper", isDirectory: true)
    }

    /// Separate from the TDT model; the leaf name must match FluidAudio's path-based variant inference.
    static var ctcDirectory: URL {
        baseDirectory.appendingPathComponent(
            "ctc/parakeet-ctc-110m-coreml", isDirectory: true)
    }
}

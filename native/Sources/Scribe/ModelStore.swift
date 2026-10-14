import Foundation

/// Single app-managed home for downloaded models. Deleting it resets all of them.
enum ModelStore {
    static let baseDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/scribe/models", isDirectory: true)

    static var gemmaDirectory: URL {
        baseDirectory.appendingPathComponent("gemma", isDirectory: true)
    }

    /// FluidAudio infers the model version from this path, so keep the repo folder name (parakeet-ultra).
    static var parakeetDirectory: URL {
        baseDirectory.appendingPathComponent(
            "parakeet/parakeet-ultra", isDirectory: true)
    }

    /// The v3 directory older installs used; Ultra falls back to it when its own download fails.
    static func parakeetV3Directory(in base: URL = baseDirectory) -> URL {
        base.appendingPathComponent("parakeet/parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    /// Removes the v3 directory an Ultra upgrade supersedes. Best-effort: a missing dir or failed delete must never fail the load that calls it.
    static func deleteSupersededParakeetV3(in base: URL = baseDirectory) {
        try? FileManager.default.removeItem(at: parakeetV3Directory(in: base))
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

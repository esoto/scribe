import Foundation

/// Minimal timestamped append-only file logger for the app-layer events
/// `AppModel` observes but that have no dedicated hook in `DictationPipeline`
/// (model load, engine switch, idle unload, install failures, notification
/// fallback). Internally serialized on a private queue so it's safe to call
/// from any thread/actor — `AppModel` stores it as `nonisolated let` so its
/// pipeline-callback closures (which run off `@MainActor`) can log without
/// hopping back to the main actor first.
///
/// Ported from the file-handler half of `scribe.app._setup_logging`
/// (src/scribe/app.py); this app logs to `~/Library/Logs/scribe/scribe.log`
/// rather than the Python app's `~/.local/state/scribe/scribe.log` per the
/// Task 13 wiring contract.
final class FileLogger: @unchecked Sendable {
    static let logsDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/scribe", isDirectory: true)
    }()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.esoto.scribe.filelogger")

    init(fileURL: URL = FileLogger.logsDirectory.appendingPathComponent("scribe.log")) {
        self.fileURL = fileURL
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func log(_ message: String) {
        queue.async { [fileURL] in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                print("[scribe] \(message)")
                return
            }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        }
    }
}

/// Writes a 16-bit PCM mono WAV file from `Float` samples in `[-1, 1]`.
///
/// Ported from `scribe.app.save_failed_audio` (src/scribe/app.py), which
/// uses Python's `wave` module; this writes the same header by hand since
/// Foundation has no built-in WAV encoder.
enum WavWriter {
    static func write(pcm: [Float], sampleRate: UInt32, to url: URL) throws {
        let samples: [Int16] = pcm.map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767.0)
        }

        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36) &+ dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLE(UInt32(16)) // fmt chunk size (PCM)
        data.appendLE(UInt16(1)) // audio format: PCM
        data.appendLE(numChannels)
        data.appendLE(sampleRate)
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(dataSize)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

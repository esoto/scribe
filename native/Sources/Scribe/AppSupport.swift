import Foundation

/// Append-only file logger. Serialized on a private queue, so it is safe to call from any thread.
/// Rotates once: when the file passes `maxBytes` the current log becomes `<name>.1` and a fresh file starts.
final class FileLogger: Sendable {
    static let logsDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/scribe", isDirectory: true)
    }()
    /// The file "Error — check log" refers to; also what Setup / Doctor's "Show Log in Finder" reveals.
    static let logFileURL = logsDirectory.appendingPathComponent("scribe.log")
    /// 5 MB is weeks of normal use; the unrotated log reached 1.7 MB in three months with every modifier key logged.
    static let defaultMaxBytes = 5 * 1024 * 1024

    private let fileURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "dev.esoto.scribe.filelogger")

    init(
        fileURL: URL = FileLogger.logFileURL,
        maxBytes: Int = FileLogger.defaultMaxBytes
    ) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func log(_ message: String) {
        queue.async { [fileURL, maxBytes] in
            Self.rotateIfNeeded(fileURL, maxBytes: maxBytes)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                // The log file itself is unwritable: stdout is the only place left.
                print("[scribe] \(message)")
                return
            }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        }
    }

    /// Waits for every queued line to be written. Tests only.
    func flush() {
        queue.sync {}
    }

    /// Keeps exactly one previous file (`scribe.log.1`): older history is not worth the disk or the attention.
    static func rotateIfNeeded(_ fileURL: URL, maxBytes: Int) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue else {
            if !fm.fileExists(atPath: fileURL.path) {   // deleted while running: start a fresh one
                try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            return
        }
        guard size >= maxBytes else { return }
        let previous = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: fileURL, to: previous)
        fm.createFile(atPath: fileURL.path, contents: nil)
    }

    /// `last_failed.wav` exists to debug a recent failure, not to keep audio around: gone after `days`.
    static func expireFailedAudio(
        in directory: URL = FileLogger.logsDirectory,
        olderThanDays days: Double = 7,
        now: Date = Date()
    ) {
        let url = directory.appendingPathComponent("last_failed.wav")
        let fm = FileManager.default
        guard let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else { return }
        if now.timeIntervalSince(modified) > days * 86_400 {
            try? fm.removeItem(at: url)
        }
    }
}

/// Hand-written WAV header: Foundation has no WAV encoder.
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
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
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

import Foundation

/// Free space on the models volume, and the message a download that won't fit shows instead of starting.
enum DiskSpace {
    /// Below this margin a download is refused even if the bytes "fit": catalog sizes are approximate and macOS needs working room.
    static let margin: Int64 = 500_000_000

    /// The models folder doesn't exist before the first download, and resource values throw for a missing path,
    /// so ask the nearest ancestor that does exist (same volume).
    static func available(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// nil when the download fits; otherwise the status-row text.
    static func shortfallMessage(label: String, needed: Int64, available: Int64?) -> String? {
        guard let available, available < needed + margin else { return nil }
        return "Not enough free disk space — \(label) needs \(formatBytes(needed + margin)), \(formatBytes(available)) free."
    }
}

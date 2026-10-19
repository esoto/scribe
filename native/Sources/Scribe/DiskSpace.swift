import Foundation

/// Free space on the models volume, and the message a download that won't fit shows instead of starting.
enum DiskSpace {
    /// Below this margin a download is refused even if the bytes "fit": the OS and the compile step need room.
    static let margin: Int64 = 500_000_000

    static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// nil when the download fits; otherwise the status-row text.
    static func shortfallMessage(label: String, needed: Int64, available: Int64?) -> String? {
        guard let available, available < needed + margin else { return nil }
        return "Not enough free disk space — \(label) needs \(formatBytes(needed)), \(formatBytes(available)) free."
    }
}

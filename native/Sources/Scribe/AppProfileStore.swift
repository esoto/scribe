import Foundation

private struct ProfilesFile: Codable {
    var version: Int
    var profiles: [AppProfile]
}

/// The user's app profiles in `profiles.json` next to the dictionary: bundle ids and rules, nothing dictated.
/// Thread-safe via a serial queue; `onChange` fires on that queue after every write.
final class AppProfileStore: @unchecked Sendable {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/scribe/profiles.json")
    private static let fileVersion = 1

    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.esoto.scribe.profiles")
    private var profiles: [AppProfile] = []
    private var changeHandler: (() -> Void)?

    init(fileURL: URL = AppProfileStore.defaultURL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        loadLocked()
    }

    var onChange: (() -> Void)? {
        get { queue.sync { changeHandler } }
        set { queue.sync { changeHandler = newValue } }
    }

    /// Sorted by app name for the Settings list.
    var all: [AppProfile] {
        queue.sync { profiles.sorted { $0.appName.lowercased() < $1.appName.lowercased() } }
    }

    /// Read on every dictation from the pipeline's thread.
    func profile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return queue.sync { profiles.first { $0.bundleID == bundleID } }
    }

    /// Replaces the profile with the same bundle id, or adds one.
    func upsert(_ profile: AppProfile) {
        queue.async {
            self.profiles.removeAll { $0.bundleID == profile.bundleID }
            self.profiles.append(profile)
            self.persistAndNotifyLocked()
        }
    }

    func remove(bundleID: String) {
        queue.async {
            self.profiles.removeAll { $0.bundleID == bundleID }
            self.persistAndNotifyLocked()
        }
    }

    private func loadLocked() {
        guard let data = try? Data(contentsOf: fileURL),
            let file = try? JSONDecoder().decode(ProfilesFile.self, from: data),
            file.version == Self.fileVersion
        else { return }
        profiles = file.profiles
    }

    private func persistAndNotifyLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(ProfilesFile(version: Self.fileVersion, profiles: profiles)) {
            try? data.write(to: fileURL, options: .atomic)
        }
        changeHandler?()
    }
}

import Foundation

/// On-disk state of MLX cleanup models in the app's Hugging Face hub cache
/// (`ModelStore.gemmaDirectory`): `models--<org>--<repo>/{blobs,refs/main,
/// snapshots/<commit>/…}`, snapshot files symlinked into `blobs/`. Sizes
/// come from `blobs/` only — walking `snapshots/` would count every file
/// twice through its symlink.
struct CleanupModelStore {
    enum Status: Equatable {
        case notDownloaded
        /// A download that started but never completed (interrupted, offline).
        case partial(bytes: Int64)
        case downloaded(bytes: Int64)

        var isDownloaded: Bool {
            if case .downloaded = self { return true }
            return false
        }

        var bytes: Int64 {
            switch self {
            case .notDownloaded: return 0
            case .partial(let bytes), .downloaded(let bytes): return bytes
            }
        }
    }

    let root: URL

    init(root: URL = ModelStore.gemmaDirectory) {
        self.root = root
    }

    func repoDirectory(_ repoID: String) -> URL {
        root.appendingPathComponent(
            "models--" + repoID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    func status(_ repoID: String) -> Status {
        let dir = repoDirectory(repoID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return .notDownloaded }
        let bytes = blobBytes(in: dir)
        if isComplete(dir) { return .downloaded(bytes: bytes) }
        return bytes > 0 ? .partial(bytes: bytes) : .notDownloaded
    }

    /// Removes the whole `models--*` directory (blobs, refs, snapshots, trees)
    /// plus the hub's `.metadata`/`.locks` sidecar folders for it if a hub
    /// version wrote any (the current cache has none; each is skipped when
    /// absent). Callers must refuse the model in use first (`canDeleteModel`).
    func delete(_ repoID: String) throws {
        let name = repoDirectory(repoID).lastPathComponent
        let targets = [
            repoDirectory(repoID),
            root.appendingPathComponent(".metadata/\(name)"),
            root.appendingPathComponent(".locks/\(name)"),
        ]
        for url in targets where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Complete = refs/main names a snapshot holding config.json plus a
    /// loadable weight set: every shard the index names, or the single-file
    /// `model.safetensors` the loader falls back to. Some repos publish a
    /// stale index beside a single-file model (gemma-3-4b-it-qat-4bit names
    /// two shards that were never uploaded), and an index alone must not
    /// report a working model as half-downloaded. `fileExists` follows
    /// symlinks, so a link whose blob never finished counts as missing.
    private func isComplete(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard
            let commit = try? String(contentsOf: dir.appendingPathComponent("refs/main"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !commit.isEmpty
        else { return false }
        let snapshot = dir.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
        guard fm.fileExists(atPath: snapshot.appendingPathComponent("config.json").path) else { return false }
        let index = snapshot.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = json["weight_map"] as? [String: String]
        {
            let shards = Set(weightMap.values)
            if shards.allSatisfy({ fm.fileExists(atPath: snapshot.appendingPathComponent($0).path) }) {
                return true
            }
        }
        return fm.fileExists(atPath: snapshot.appendingPathComponent("model.safetensors").path)
    }

    private func blobBytes(in dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let files = FileManager.default.enumerator(
                at: dir.appendingPathComponent("blobs", isDirectory: true),
                includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

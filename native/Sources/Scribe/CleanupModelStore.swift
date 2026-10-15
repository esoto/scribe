import Foundation

/// On-disk state of MLX cleanup models in the app's Hugging Face hub cache
/// (`ModelStore.gemmaDirectory`): `models--<org>--<repo>/{blobs,snapshots/
/// <commit>/…}`, snapshot files symlinked into `blobs/`. Installs made before
/// models were pinned also have `refs/main` naming their commit. Sizes come
/// from `blobs/` only — walking `snapshots/` would count every file twice
/// through its symlink.
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

    /// `revision` defaults to the catalog's pin for `repoID` (else `main`), so a
    /// caller that only knows the repo reports the commit the app will load.
    func status(_ repoID: String, revision: String? = nil) -> Status {
        let dir = repoDirectory(repoID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return .notDownloaded }
        let bytes = blobBytes(in: dir)
        let revision = revision ?? CleanupModelCatalog.pinnedRevision(repoID: repoID) ?? "main"
        if snapshotDirectory(repoID: repoID, revision: revision) != nil { return .downloaded(bytes: bytes) }
        return bytes > 0 ? .partial(bytes: bytes) : .notDownloaded
    }

    /// The snapshot for `revision` if it is complete, else nil. A commit hash
    /// names `snapshots/<commit>` directly: a pinned download writes no `refs/`
    /// entry, and a legacy install whose `refs/main` points at the same commit
    /// has that directory too, so both layouts pass without a re-download. Any
    /// other revision is a ref name read from `refs/<revision>`.
    func snapshotDirectory(repoID: String, revision: String) -> URL? {
        let dir = repoDirectory(repoID)
        let commit: String
        if Self.isCommitHash(revision) {
            commit = revision
        } else if let ref = try? String(
            contentsOf: dir.appendingPathComponent("refs/\(revision)"), encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            commit = ref
        } else {
            return nil
        }
        let snapshot = dir.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
        return isComplete(snapshot) ? snapshot : nil
    }

    /// Same test swift-huggingface uses to treat a revision as a commit rather than a ref.
    private static func isCommitHash(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }

    /// Removes the whole `models--*` directory (blobs, refs, snapshots, trees)
    /// plus the hub's `.metadata`/`.locks` sidecar folders for it (pinned
    /// downloads write `.metadata/<repo>/<commit>.json`; each is skipped when
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

    /// Complete = the snapshot holds everything a directory load needs:
    /// config.json, tokenizer.json, tokenizer_config.json (without it the
    /// tokenizer class is guessed and strict mode throws), a chat template
    /// (.jinja or .json; without one every clean() fails) and a
    /// loadable weight set: every shard the index names, or the single-file
    /// `model.safetensors` the loader falls back to. Some repos publish a
    /// stale index beside a single-file model (gemma-3-4b-it-qat-4bit names
    /// two shards that were never uploaded), and an index alone must not
    /// report a working model as half-downloaded. `fileExists` follows
    /// symlinks, so a link whose blob never finished counts as missing. The
    /// small files are required because a directory load, unlike a load by id,
    /// cannot fetch one an interrupted download never wrote.
    private func isComplete(_ snapshot: URL) -> Bool {
        let fm = FileManager.default
        let has = { (name: String) in fm.fileExists(atPath: snapshot.appendingPathComponent(name).path) }
        guard ["config.json", "tokenizer.json", "tokenizer_config.json"].allSatisfy(has),
            has("chat_template.jinja") || has("chat_template.json")
        else { return false }
        let index = snapshot.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = json["weight_map"] as? [String: String]
        {
            let shards = Set(weightMap.values)
            if shards.allSatisfy(has) { return true }
        }
        return has("model.safetensors")
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

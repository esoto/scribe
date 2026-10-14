import XCTest

final class CleanupModelStoreTests: XCTestCase {
    private var root: URL!
    private let repo = "mlx-community/test-model"
    private var store: CleanupModelStore { CleanupModelStore(root: root) }

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Builds a hub-cache repo mirroring the REAL on-disk layout
    /// (`models--mlx-community--gemma-3-4b-it-qat-4bit`): `blobs/`,
    /// `refs/main`, `snapshots/<commit>/` whose entries are RELATIVE symlinks
    /// (`../../blobs/<blob>`), and a `trees/<commit>.json`. There are NO
    /// `.metadata/` or `.locks/` sidecars in the real cache.
    private func makeRepo(_ files: [String: Int], shards: [String]? = nil, writeRef: Bool = true) throws {
        let fm = FileManager.default
        let dir = store.repoDirectory(repo)
        let blobs = dir.appendingPathComponent("blobs", isDirectory: true)
        let snap = dir.appendingPathComponent("snapshots/abc123", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        let trees = dir.appendingPathComponent("trees", isDirectory: true)
        try fm.createDirectory(at: trees, withIntermediateDirectories: true)
        try Data(count: 500).write(to: trees.appendingPathComponent("abc123.json"))  // must not count toward size
        for (name, size) in files {
            try Data(count: size).write(to: blobs.appendingPathComponent("blob-\(name)"))
            try fm.createSymbolicLink(
                atPath: snap.appendingPathComponent(name).path, withDestinationPath: "../../blobs/blob-\(name)")
        }
        if let shards {
            let map = Dictionary(uniqueKeysWithValues: shards.enumerated().map { ("layer\($0.offset)", $0.element) })
            let data = try JSONSerialization.data(withJSONObject: ["weight_map": map])
            try data.write(to: snap.appendingPathComponent("model.safetensors.index.json"))
        }
        if writeRef {
            try fm.createDirectory(at: dir.appendingPathComponent("refs"), withIntermediateDirectories: true)
            try "abc123".write(to: dir.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        }
    }

    func testRepoDirectoryUsesHubNaming() {
        XCTAssertEqual(
            store.repoDirectory("mlx-community/gemma-4-e4b-it-4bit").lastPathComponent,
            "models--mlx-community--gemma-4-e4b-it-4bit")
    }

    func testMissingRepoIsNotDownloaded() {
        XCTAssertEqual(store.status(repo), .notDownloaded)
    }

    /// Snapshot entries are symlinks into blobs/ — counting both would double
    /// the size — and trees/*.json (500 bytes in the fixture) is not model data.
    func testCompleteModelReportsBlobBytesOnce() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000])
        XCTAssertEqual(store.status(repo), .downloaded(bytes: 1010))
    }

    func testShardedModelNeedsEveryShard() throws {
        try makeRepo(["config.json": 10, "a.safetensors": 100], shards: ["a.safetensors", "b.safetensors"])
        XCTAssertEqual(store.status(repo), .partial(bytes: 110))
    }

    func testShardedModelWithAllShardsIsDownloaded() throws {
        try makeRepo(
            ["config.json": 10, "a.safetensors": 100, "b.safetensors": 100],
            shards: ["a.safetensors", "b.safetensors"])
        XCTAssertEqual(store.status(repo), .downloaded(bytes: 210))
    }

    /// The real gemma-3-4b-it-qat-4bit cache: the index names two shards that
    /// were never published, while model.safetensors holds the whole model.
    /// Reporting that as "incomplete" hides a working model and offers no way
    /// to fix it from the UI (the active model can't be deleted or re-used).
    func testStaleIndexWithCompleteSingleFileIsDownloaded() throws {
        try makeRepo(
            ["config.json": 10, "model.safetensors": 1000],
            shards: ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])
        XCTAssertEqual(store.status(repo), .downloaded(bytes: 1010))
    }

    func testMissingRefMeansPartial() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000], writeRef: false)
        XCTAssertEqual(store.status(repo), .partial(bytes: 1010))
    }

    /// The real cache has no sidecars: delete must tolerate their absence and
    /// remove the WHOLE `models--*` directory (blobs, refs, snapshots, trees).
    func testDeleteWithoutSidecarsRemovesTheWholeRepoDirectory() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000])
        let dir = store.repoDirectory(repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("trees").path))
        try store.delete(repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(store.status(repo), .notDownloaded)
    }

    /// Defensive: other hub versions do write sidecars; delete clears them too.
    func testDeleteRemovesRepoAndHubSidecars() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000])
        let name = store.repoDirectory(repo).lastPathComponent
        let sidecars = [root.appendingPathComponent(".metadata/\(name)"), root.appendingPathComponent(".locks/\(name)")]
        for url in sidecars { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try store.delete(repo)
        XCTAssertEqual(store.status(repo), .notDownloaded)
        for url in sidecars { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testStatusHelpers() {
        XCTAssertTrue(CleanupModelStore.Status.downloaded(bytes: 5).isDownloaded)
        XCTAssertFalse(CleanupModelStore.Status.partial(bytes: 5).isDownloaded)
        XCTAssertEqual(CleanupModelStore.Status.partial(bytes: 5).bytes, 5)
        XCTAssertEqual(CleanupModelStore.Status.notDownloaded.bytes, 0)
    }
}

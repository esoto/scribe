import MLXLMCommon
import XCTest

final class CleanupModelStoreTests: XCTestCase {
    private var root: URL!
    private let repo = "mlx-community/test-model"
    private let pinned = "3d9ef289111449933c22761961f16a5df237ce2a"
    private let otherCommit = "0123456789abcdef0123456789abcdef01234567"
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

    /// Builds a hub-cache repo in the LEGACY on-disk layout written before models
    /// were pinned (`models--mlx-community--gemma-3-4b-it-qat-4bit`): `blobs/`,
    /// `refs/main`, `snapshots/<commit>/` whose entries are RELATIVE symlinks
    /// (`../../blobs/<blob>`), and a `trees/<commit>.json`. It writes no
    /// `.metadata/` or `.locks/` sidecars; the tests that need them add their own.
    /// `writeRef: false` gives the pinned-download layout instead. The files a
    /// directory load needs besides weights and config.json
    /// are added empty unless named in `omitting`.
    private func makeRepo(
        _ files: [String: Int], shards: [String]? = nil, writeRef: Bool = true,
        repoID: String? = nil, commit: String = "abc123", omitting: Set<String> = []
    ) throws {
        let fm = FileManager.default
        var files = files
        for name in ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja"]
        where files[name] == nil && !omitting.contains(name) {
            files[name] = 0
        }
        let dir = store.repoDirectory(repoID ?? repo)
        let blobs = dir.appendingPathComponent("blobs", isDirectory: true)
        let snap = dir.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        let trees = dir.appendingPathComponent("trees", isDirectory: true)
        try fm.createDirectory(at: trees, withIntermediateDirectories: true)
        try Data(count: 500).write(to: trees.appendingPathComponent("\(commit).json"))  // must not count toward size
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
            try commit.write(to: dir.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
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

    /// A repo without sidecars: delete must tolerate their absence and
    /// remove the WHOLE `models--*` directory (blobs, refs, snapshots, trees).
    func testDeleteWithoutSidecarsRemovesTheWholeRepoDirectory() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000])
        let dir = store.repoDirectory(repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("trees").path))
        try store.delete(repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(store.status(repo), .notDownloaded)
    }

    /// Every download leaves `.locks` and pinned ones `.metadata`; delete clears both.
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

    // MARK: - Pinned revisions

    /// What a SHA-pinned download leaves behind: swift-huggingface passes no ref
    /// for a commit-hash revision, so `refs/` never exists.
    func testPinnedSnapshotWithoutRefsIsComplete() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: pinned)
        XCTAssertEqual(
            store.snapshotDirectory(repoID: repo, revision: pinned),
            store.repoDirectory(repo).appendingPathComponent("snapshots/\(pinned)", isDirectory: true))
        XCTAssertEqual(store.status(repo, revision: pinned), .downloaded(bytes: 1010))
    }

    func testOtherCommitIsIncompleteForThePin() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: pinned)
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: otherCommit))
        XCTAssertEqual(store.status(repo, revision: otherCommit), .partial(bytes: 1010))
    }

    /// Existing installs have refs/main -> the commit they downloaded. When it
    /// is the pinned commit nothing may be re-downloaded, and nothing rewritten.
    func testLegacyRefsMainLayoutIsCompleteForTheMatchingPin() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000], commit: pinned)
        let ref = store.repoDirectory(repo).appendingPathComponent("refs/main")
        XCTAssertEqual(store.status(repo, revision: pinned), .downloaded(bytes: 1010))
        XCTAssertEqual(store.status(repo, revision: "main"), .downloaded(bytes: 1010))
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), pinned)
        XCTAssertNotNil(store.snapshotDirectory(repoID: repo, revision: pinned))
    }

    /// A legacy snapshot at a different commit is not the pinned model: it
    /// reports incomplete (so the pin is fetched) but the files are left alone.
    func testLegacyInstallAtAnotherCommitIsNotThePinnedModel() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000], commit: otherCommit)
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: pinned))
        XCTAssertEqual(store.status(repo, revision: pinned), .partial(bytes: 1010))
        XCTAssertEqual(store.status(repo, revision: "main"), .downloaded(bytes: 1010))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.repoDirectory(repo).appendingPathComponent("snapshots/\(otherCommit)").path))
    }

    /// A directory load cannot fetch what an interrupted download never wrote, so a
    /// snapshot missing any file the loader needs must not take the local-first path.
    func testSnapshotWithoutTokenizerIsIncomplete() throws {
        try makeRepo(
            ["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: pinned,
            omitting: ["tokenizer.json"])
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: pinned))
        XCTAssertEqual(store.status(repo, revision: pinned), .partial(bytes: 1010))
    }

    /// Without tokenizer_config.json the tokenizer class is guessed and strict mode throws.
    func testSnapshotWithoutTokenizerConfigIsIncomplete() throws {
        try makeRepo(
            ["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: pinned,
            omitting: ["tokenizer_config.json"])
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: pinned))
        XCTAssertEqual(store.status(repo, revision: pinned), .partial(bytes: 1010))
    }

    /// Without a chat template the prompt goes to the model untemplated and cleanup silently degrades.
    func testSnapshotWithoutChatTemplateIsIncomplete() throws {
        try makeRepo(
            ["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: pinned,
            omitting: ["chat_template.jinja"])
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: pinned))
        XCTAssertEqual(store.status(repo, revision: pinned), .partial(bytes: 1010))
    }

    /// Gemma 3 ships chat_template.json rather than .jinja.
    func testChatTemplateJsonAloneSatisfiesTheTemplateRequirement() throws {
        try makeRepo(
            ["config.json": 10, "model.safetensors": 1000, "chat_template.json": 5], writeRef: false,
            commit: pinned, omitting: ["chat_template.jinja"])
        XCTAssertNotNil(store.snapshotDirectory(repoID: repo, revision: pinned))
        XCTAssertEqual(store.status(repo, revision: pinned), .downloaded(bytes: 1015))
    }

    /// A symlink whose blob never finished downloading counts as missing.
    func testDanglingWeightLinkIsIncomplete() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: pinned)
        try FileManager.default.removeItem(
            at: store.repoDirectory(repo).appendingPathComponent("blobs/blob-model.safetensors"))
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: pinned))
        XCTAssertEqual(store.status(repo, revision: pinned), .partial(bytes: 10))
    }

    func testPinnedSnapshotWithoutWeightsIsIncomplete() throws {
        try makeRepo(["config.json": 10], writeRef: false, commit: pinned)
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: pinned))
        XCTAssertEqual(store.status(repo, revision: pinned), .partial(bytes: 10))
    }

    func testBranchRevisionStillNeedsItsRef() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: pinned)
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: "main"))
    }

    /// Only a real 40-hex commit skips refs/; anything else is a ref name.
    func testFortyNonHexCharactersIsABranchName() throws {
        let notASHA = String(repeating: "z", count: 40)
        try makeRepo(["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: notASHA)
        XCTAssertNil(store.snapshotDirectory(repoID: repo, revision: notASHA))
    }

    /// Callers that only know the repo (the menu, the models window) get the
    /// catalog's pin, so a fresh pinned download is not reported "incomplete".
    func testStatusDefaultsToTheCatalogPin() throws {
        let spec = CleanupModelCatalog.gemma3
        let repoID = try XCTUnwrap(spec.repoID)
        try makeRepo(
            ["config.json": 10, "model.safetensors": 1000], writeRef: false,
            repoID: repoID, commit: try XCTUnwrap(spec.revision))
        XCTAssertEqual(store.status(repoID), .downloaded(bytes: 1010))
        XCTAssertEqual(store.status(repoID, revision: otherCommit), .partial(bytes: 1010))
    }

    func testDeleteRemovesAPinnedDownloadsMetadataSidecar() throws {
        try makeRepo(["config.json": 10, "model.safetensors": 1000], writeRef: false, commit: pinned)
        let sidecar = root.appendingPathComponent(".metadata/\(store.repoDirectory(repo).lastPathComponent)")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sidecar.appendingPathComponent("\(pinned).json"))
        try store.delete(repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(store.status(repo, revision: pinned), .notDownloaded)
    }

    // MARK: - Local-first model configuration

    private final class SpyDownloader: Downloader, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(id: String, revision: String?)] = []
        var calls: [(id: String, revision: String?)] { lock.withLock { recorded } }

        func download(
            id: String, revision: String?, matching patterns: [String], useLatest: Bool,
            progressHandler: @Sendable @escaping (Progress) -> Void
        ) async throws -> URL {
            lock.withLock { recorded.append((id, revision)) }
            return FileManager.default.temporaryDirectory
        }
    }

    func testCompletePinnedSnapshotLoadsFromDiskWithoutTheDownloader() async throws {
        let spec = CleanupModelCatalog.gemma3
        let repoID = try XCTUnwrap(spec.repoID)
        let revision = try XCTUnwrap(spec.revision)
        try makeRepo(
            ["config.json": 10, "model.safetensors": 1000], writeRef: false, repoID: repoID, commit: revision)
        let config = GemmaBackend.localFirstConfiguration(spec: spec, store: store)
        let spy = SpyDownloader()
        let resolved = try await resolve(configuration: config, from: spy, useLatest: false) { _ in }
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertEqual(resolved.modelDirectory, store.snapshotDirectory(repoID: repoID, revision: revision))
        XCTAssertEqual(resolved.extraEOSTokens, ["<end_of_turn>"])
    }

    func testMissingSnapshotDownloadsExactlyThePinnedRevision() async throws {
        let spec = CleanupModelCatalog.gemma4
        let config = GemmaBackend.localFirstConfiguration(spec: spec, store: store)
        let spy = SpyDownloader()
        _ = try await resolve(configuration: config, from: spy, useLatest: false) { _ in }
        XCTAssertEqual(spy.calls.map(\.id), ["mlx-community/gemma-4-e4b-it-4bit"])
        XCTAssertEqual(spy.calls.map(\.revision), [spec.revision])
        XCTAssertEqual(config.extraEOSTokens, ["<turn|>"])
    }

    func testIncompletePinnedSnapshotFallsBackToTheDownloader() async throws {
        let spec = CleanupModelCatalog.gemma4e2b
        try makeRepo(
            ["config.json": 10], writeRef: false, repoID: try XCTUnwrap(spec.repoID),
            commit: try XCTUnwrap(spec.revision))
        let config = GemmaBackend.localFirstConfiguration(spec: spec, store: store)
        let spy = SpyDownloader()
        _ = try await resolve(configuration: config, from: spy, useLatest: false) { _ in }
        XCTAssertEqual(spy.calls.map(\.revision), [spec.revision])
    }

    func testCustomPathIgnoresALocalSnapshot() throws {
        let spec = CleanupModelCatalog.gemma3
        try makeRepo(
            ["config.json": 10, "model.safetensors": 1000], writeRef: false,
            repoID: try XCTUnwrap(spec.repoID), commit: try XCTUnwrap(spec.revision))
        let config = GemmaBackend.localFirstConfiguration(spec: spec, customPath: "/tmp/my-model", store: store)
        XCTAssertEqual(config.id, .directory(URL(fileURLWithPath: "/tmp/my-model")))
        XCTAssertTrue(config.extraEOSTokens.isEmpty)
    }
}

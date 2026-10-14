import XCTest


final class ModelStoreTests: XCTestCase {
    func testAllModelsLiveUnderTheAppStore() {
        let base = ModelStore.baseDirectory.path
        XCTAssertTrue(base.hasSuffix("Library/Application Support/scribe/models"))
        for dir in [ModelStore.gemmaDirectory, ModelStore.parakeetDirectory, ModelStore.whisperDirectory] {
            XCTAssertTrue(dir.path.hasPrefix(base), "\(dir.path) escaped the store")
        }
    }

    // FluidAudio infers the model version from the directory name; keep the repo folder name.
    func testParakeetDirectoryKeepsRepoFolderName() {
        XCTAssertEqual(ModelStore.parakeetDirectory.lastPathComponent, "parakeet-ultra")
    }

    func testDeleteSupersededParakeetV3RemovesOnlyTheV3Directory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)")
        let v3 = base.appendingPathComponent("parakeet/parakeet-tdt-0.6b-v3", isDirectory: true)
        let ultra = base.appendingPathComponent("parakeet/parakeet-ultra", isDirectory: true)
        try FileManager.default.createDirectory(at: v3, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ultra, withIntermediateDirectories: true)

        ModelStore.deleteSupersededParakeetV3(in: base)

        XCTAssertFalse(FileManager.default.fileExists(atPath: v3.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ultra.path), "only the v3 leaf may go, not its parent")
        try? FileManager.default.removeItem(at: base)
    }

    // A fresh install has no v3 directory; the cleanup must tolerate that.
    func testDeleteSupersededParakeetV3ToleratesMissingDirectory() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)")

        ModelStore.deleteSupersededParakeetV3(in: base)

        try? FileManager.default.removeItem(at: base)
    }

    private func makeSettings() -> (AppSettings, UserDefaults) {
        let suite = "ModelStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: defaults), defaults)
    }

    func testCleanupModelPathDefaultsToNil() {
        let (settings, _) = makeSettings()
        XCTAssertNil(settings.cleanupModelPath)
    }

    func testCleanupModelPathRoundtrips() {
        let (settings, _) = makeSettings()
        settings.cleanupModelPath = "/tmp/my-model"
        XCTAssertEqual(settings.cleanupModelPath, "/tmp/my-model")
    }

    func testBlankCleanupModelPathCountsAsUnset() {
        let (settings, defaults) = makeSettings()
        defaults.set("   ", forKey: "cleanupModelPath")
        XCTAssertNil(settings.cleanupModelPath)
    }

    func testDefaultConfigurationKeepsGemmaStopToken() {
        let config = GemmaBackend.modelConfiguration()
        XCTAssertEqual(config.extraEOSTokens, ["<end_of_turn>"])
    }

    // Custom models must not inherit Gemma's <end_of_turn> stop token; it corrupts their output.
    func testCustomConfigurationCarriesNoGemmaStopToken() {
        let config = GemmaBackend.modelConfiguration(customPath: "/tmp/my-model")
        XCTAssertTrue(config.extraEOSTokens.isEmpty)
    }

    func testGemma4ConfigurationUsesItsOwnTurnToken() {
        let config = GemmaBackend.modelConfiguration(spec: CleanupModelCatalog.gemma4)
        XCTAssertEqual(config.extraEOSTokens, ["<turn|>"])
        XCTAssertEqual(config.name, "mlx-community/gemma-4-e4b-it-4bit")
    }

    func testCustomPathIgnoresTheSpecStopTokens() {
        let config = GemmaBackend.modelConfiguration(spec: CleanupModelCatalog.gemma4, customPath: "/tmp/my-model")
        XCTAssertTrue(config.extraEOSTokens.isEmpty)
    }

    /// Constructing a backend must not load a model — only conformance is checked.
    func testGemmaBackendIsACleanupModelBackend() {
        let backend: any CleanupModelBackend = GemmaBackend(spec: CleanupModelCatalog.gemma4)
        backend.setDictionary(.empty)
        XCTAssertTrue(backend.holdsMemory)
    }
}

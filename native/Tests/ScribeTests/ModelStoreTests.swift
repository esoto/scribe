import XCTest

@testable import Scribe

final class ModelStoreTests: XCTestCase {
    func testAllModelsLiveUnderTheAppStore() {
        let base = ModelStore.baseDirectory.path
        XCTAssertTrue(base.hasSuffix("Library/Application Support/scribe/models"))
        for dir in [ModelStore.gemmaDirectory, ModelStore.parakeetDirectory, ModelStore.whisperDirectory] {
            XCTAssertTrue(dir.path.hasPrefix(base), "\(dir.path) escaped the store")
        }
    }

    /// FluidAudio infers the model version from the directory name, so the
    /// leaf must keep the repo folder name.
    func testParakeetDirectoryKeepsRepoFolderName() {
        XCTAssertEqual(ModelStore.parakeetDirectory.lastPathComponent, "parakeet-tdt-0.6b-v3")
    }

    // MARK: - cleanupModelPath setting

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

    // MARK: - modelConfiguration(customPath:)

    func testDefaultConfigurationKeepsGemmaStopToken() {
        let config = GemmaBackend.modelConfiguration()
        XCTAssertEqual(config.extraEOSTokens, ["<end_of_turn>"])
    }

    /// A custom model must NOT inherit Gemma's turn token — forcing
    /// `<end_of_turn>` onto another model family corrupts its output.
    func testCustomConfigurationCarriesNoGemmaStopToken() {
        let config = GemmaBackend.modelConfiguration(customPath: "/tmp/my-model")
        XCTAssertTrue(config.extraEOSTokens.isEmpty)
    }
}

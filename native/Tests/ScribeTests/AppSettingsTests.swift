import XCTest

final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaults() {
        XCTAssertEqual(settings.hotkey, .rightOption)
        XCTAssertEqual(settings.holdThreshold, 0.3)
        XCTAssertEqual(settings.engine, "parakeet")
        XCTAssertEqual(settings.cleanupEnabled, true)
        XCTAssertEqual(settings.minWords, 4)
        XCTAssertEqual(settings.cleanupTimeout, 6.0)
        XCTAssertEqual(settings.lengthBand.0, 0.5)
        XCTAssertEqual(settings.lengthBand.1, 1.3)
        XCTAssertEqual(settings.restoreDelay, 2.0)
        XCTAssertEqual(settings.energyGate, 0.0005)
        XCTAssertEqual(settings.sounds, true)
        XCTAssertEqual(settings.historySize, 10)
        XCTAssertEqual(settings.idleUnloadMinutes, 15)
        // Off by default: the learned-vocabulary prompt section drops words.
        XCTAssertEqual(settings.dictionaryLearningEnabled, false)
        XCTAssertEqual(settings.vocabularyBiasingEnabled, false)
        XCTAssertNil(settings.cleanupModel)
    }

    // MARK: - Round-trip set/get

    func testRoundTripSetGet() {
        settings.hotkey = .f13
        settings.holdThreshold = 0.5
        settings.engine = "whisper"
        settings.cleanupEnabled = false
        settings.minWords = 7
        settings.cleanupTimeout = 9.5
        settings.lengthBand = (0.7, 1.9)
        settings.restoreDelay = 3.0
        settings.energyGate = 0.001
        settings.sounds = false
        settings.historySize = 25
        settings.idleUnloadMinutes = 30
        settings.dictionaryLearningEnabled = true
        settings.vocabularyBiasingEnabled = true

        XCTAssertEqual(settings.hotkey, .f13)
        XCTAssertEqual(settings.holdThreshold, 0.5)
        XCTAssertEqual(settings.engine, "whisper")
        XCTAssertEqual(settings.cleanupEnabled, false)
        XCTAssertEqual(settings.minWords, 7)
        XCTAssertEqual(settings.cleanupTimeout, 9.5)
        XCTAssertEqual(settings.lengthBand.0, 0.7)
        XCTAssertEqual(settings.lengthBand.1, 1.9)
        XCTAssertEqual(settings.restoreDelay, 3.0)
        XCTAssertEqual(settings.energyGate, 0.001)
        XCTAssertEqual(settings.sounds, false)
        XCTAssertEqual(settings.historySize, 25)
        XCTAssertEqual(settings.idleUnloadMinutes, 30)
        XCTAssertEqual(settings.dictionaryLearningEnabled, true)
        XCTAssertEqual(settings.vocabularyBiasingEnabled, true)
    }

    func testRoundTripPersistsAcrossInstances() {
        settings.engine = "whisper"
        settings.minWords = 99

        let other = AppSettings(defaults: defaults)
        XCTAssertEqual(other.engine, "whisper")
        XCTAssertEqual(other.minWords, 99)
    }

    func testCleanupModelRoundTrips() {
        settings.cleanupModel = "gemma4"
        XCTAssertEqual(settings.cleanupModel, "gemma4")
        XCTAssertEqual(AppSettings(defaults: defaults).cleanupModel, "gemma4")
    }

    func testEnhanceAudioDefaultsOff() {
        XCTAssertFalse(settings.enhanceAudioEnabled)
    }

    func testEnhanceAudioRoundTrips() {
        settings.enhanceAudioEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).enhanceAudioEnabled)
        settings.enhanceAudioEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).enhanceAudioEnabled)
    }

    // MARK: - importToml

    private let sampleToml = """
    [hotkey]
    key = "f13"
    [audio]
    energy_gate_rms = 0.001
    [cleanup]
    length_band = [0.4, 1.5]
    banana = 1
    """

    func testImportTomlMapsKnownKeys() {
        let result = AppSettings.importToml(sampleToml)

        XCTAssertEqual(result["hotkey"] as? String, "f13")
        XCTAssertEqual(result["energyGate"] as? Double, 0.001)

        guard let band = result["lengthBand"] as? [Double] else {
            XCTFail("expected lengthBand to parse as [Double]")
            return
        }
        XCTAssertEqual(band, [0.4, 1.5])
    }

    func testImportTomlIgnoresUnknownKeys() {
        let result = AppSettings.importToml(sampleToml)
        XCTAssertNil(result["banana"])
        XCTAssertNil(result["cleanup.banana"])
    }

    func testImportTomlTrivialCases() {
        XCTAssertEqual(AppSettings.importToml("").count, 0)
        XCTAssertEqual(AppSettings.importToml("   \n\n  ").count, 0)
    }

    func testImportTomlTolerateJunkLines() {
        let junky = """
        this is not valid toml at all
        [hotkey]
        # a comment line
        key = "right_command"
        = missing key
        no_equals_sign_here
        [audio]
        energy_gate_rms = 0.002  # inline comment
        [stt]
        engine = "whisper"
        """
        let result = AppSettings.importToml(junky)
        XCTAssertEqual(result["hotkey"] as? String, "right_command")
        XCTAssertEqual(result["energyGate"] as? Double, 0.002)
        XCTAssertEqual(result["engine"] as? String, "whisper")
    }

    func testImportTomlRejectsInvalidHotkeyValue() {
        let toml = """
        [hotkey]
        key = "not_a_real_key"
        """
        let result = AppSettings.importToml(toml)
        XCTAssertNil(result["hotkey"])
    }

    func testImportTomlParsesAllKnownMappings() {
        let toml = """
        [hotkey]
        key = "right_command"
        hold_threshold_s = 0.4
        [stt]
        engine = "whisper"
        [cleanup]
        enabled = false
        min_words = 6
        timeout_s = 8.0
        length_band = [0.6, 1.4]
        [paste]
        clipboard_restore_delay_s = 1.5
        [audio]
        energy_gate_rms = 0.0009
        [ui]
        sounds = false
        history_size = 20
        [memory]
        idle_unload_minutes = 25
        """
        let result = AppSettings.importToml(toml)

        XCTAssertEqual(result["hotkey"] as? String, "right_command")
        XCTAssertEqual(result["holdThreshold"] as? Double, 0.4)
        XCTAssertEqual(result["engine"] as? String, "whisper")
        XCTAssertEqual(result["cleanupEnabled"] as? Bool, false)
        XCTAssertEqual(result["minWords"] as? Int, 6)
        XCTAssertEqual(result["cleanupTimeout"] as? Double, 8.0)
        XCTAssertEqual(result["lengthBand"] as? [Double], [0.6, 1.4])
        XCTAssertEqual(result["restoreDelay"] as? Double, 1.5)
        XCTAssertEqual(result["energyGate"] as? Double, 0.0009)
        XCTAssertEqual(result["sounds"] as? Bool, false)
        XCTAssertEqual(result["historySize"] as? Int, 20)
        XCTAssertEqual(result["idleUnloadMinutes"] as? Double, 25)
    }

    // MARK: - importFromPythonConfigOnce

    func testImportFromPythonConfigOnceAppliesSettingsExceptHotkey() {
        settings.importFromPythonConfigOnce(tomlText: sampleToml)

        // The hotkey is never imported and stays at the dev default.
        XCTAssertEqual(settings.hotkey, .rightOption)
        XCTAssertEqual(settings.energyGate, 0.001)
        XCTAssertEqual(settings.lengthBand.0, 0.4)
        XCTAssertEqual(settings.lengthBand.1, 1.5)
    }

    func testImportFromPythonConfigOnceSetsFlag() {
        XCTAssertFalse(defaults.bool(forKey: "didImportToml"))
        settings.importFromPythonConfigOnce(tomlText: sampleToml)
        XCTAssertTrue(defaults.bool(forKey: "didImportToml"))
    }

    func testImportFromPythonConfigOnceDoesNotImportTwice() {
        settings.importFromPythonConfigOnce(tomlText: sampleToml)
        XCTAssertEqual(settings.energyGate, 0.001)

        let secondToml = """
        [audio]
        energy_gate_rms = 0.05
        """
        settings.importFromPythonConfigOnce(tomlText: secondToml)

        XCTAssertEqual(settings.energyGate, 0.001)
    }

    func testImportFromPythonConfigOnceWithMissingFileStillSetsFlag() {
        // The flag must be set whether or not a real dev config exists.
        settings.importFromPythonConfigOnce()
        XCTAssertTrue(defaults.bool(forKey: "didImportToml"))
    }

    // MARK: - 1.4 keys

    func testOneFourDefaults() {
        XCTAssertTrue(settings.voiceCommandsEnabled)
        // Off by default: any process can open a URL scheme.
        XCTAssertFalse(settings.urlSchemeEnabled)
        XCTAssertTrue(settings.hudEnabled)
        XCTAssertEqual(settings.hotkeyMode, .hold)
    }

    func testOneFourKeysRoundTrip() {
        settings.voiceCommandsEnabled = false
        settings.urlSchemeEnabled = true
        settings.hudEnabled = false
        settings.hotkeyMode = .holdOrLatch

        let other = AppSettings(defaults: defaults)
        XCTAssertFalse(other.voiceCommandsEnabled)
        XCTAssertTrue(other.urlSchemeEnabled)
        XCTAssertFalse(other.hudEnabled)
        XCTAssertEqual(other.hotkeyMode, .holdOrLatch)
    }

    func testUnknownHotkeyModeFallsBackToHold() {
        defaults.set("latch", forKey: "hotkeyMode")
        XCTAssertEqual(settings.hotkeyMode, .hold)
    }
}

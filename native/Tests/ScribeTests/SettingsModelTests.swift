import XCTest

@MainActor
final class SettingsModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var hotkeys: [HotKey] = []
    private var thresholds: [Double] = []
    private var idleMinutes: [Double] = []
    private var historySizes: [Int] = []
    /// What `AppSettings` held at the moment each effect ran: the effect must see the persisted value.
    private var storedHotkeyAtEffect: [HotKey] = []

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
        hotkeys = []
        thresholds = []
        idleMinutes = []
        historySizes = []
        storedHotkeyAtEffect = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    private func make() -> SettingsModel {
        let settings = self.settings!
        return SettingsModel(
            settings: settings,
            onHotkeyChanged: { [unowned self] key in
                hotkeys.append(key)
                storedHotkeyAtEffect.append(settings.hotkey)
            },
            onHoldThresholdChanged: { [unowned self] in thresholds.append($0) },
            onIdleMinutesChanged: { [unowned self] in idleMinutes.append($0) },
            onHistorySizeChanged: { [unowned self] in historySizes.append($0) })
    }

    func testMirrorsTheDefaultsWhenNothingIsStored() {
        let model = make()

        XCTAssertEqual(model.hotkey, .rightOption)
        XCTAssertEqual(model.holdThreshold, 0.3)
        XCTAssertTrue(model.sounds)
        XCTAssertEqual(model.idleUnloadMinutes, 15)
        XCTAssertEqual(model.historySize, 10)
    }

    func testMirrorsWhatIsStored() {
        settings.hotkey = .f13
        settings.holdThreshold = 0.6
        settings.sounds = false
        settings.idleUnloadMinutes = 0
        settings.historySize = 25

        let model = make()

        XCTAssertEqual(model.hotkey, .f13)
        XCTAssertEqual(model.holdThreshold, 0.6)
        XCTAssertFalse(model.sounds)
        XCTAssertEqual(model.idleUnloadMinutes, 0)
        XCTAssertEqual(model.historySize, 25)
    }

    func testBuildingTheModelFiresNoEffects() {
        _ = make()

        XCTAssertEqual(hotkeys, [])
        XCTAssertEqual(thresholds, [])
        XCTAssertEqual(idleMinutes, [])
        XCTAssertEqual(historySizes, [])
    }

    func testSetHotkeyPersistsThenFiresOnceAndIgnoresARepeat() {
        let model = make()

        model.setHotkey(.f13)
        model.setHotkey(.f13)

        XCTAssertEqual(model.hotkey, .f13)
        XCTAssertEqual(settings.hotkey, .f13)
        XCTAssertEqual(hotkeys, [.f13])
        XCTAssertEqual(storedHotkeyAtEffect, [.f13])
    }

    func testSettingTheStoredHotkeyAgainIsANoOp() {
        let model = make()

        model.setHotkey(.rightOption)

        XCTAssertEqual(hotkeys, [])
    }

    func testSetHoldThresholdPersistsAndFiresOnce() {
        let model = make()

        model.setHoldThreshold(0.5)
        model.setHoldThreshold(0.5)

        XCTAssertEqual(model.holdThreshold, 0.5)
        XCTAssertEqual(settings.holdThreshold, 0.5)
        XCTAssertEqual(thresholds, [0.5])
    }

    func testSetSoundsPersistsWithoutAnEffect() {
        let model = make()

        model.setSounds(false)

        XCTAssertFalse(model.sounds)
        XCTAssertFalse(settings.sounds)
    }

    func testSettingSoundsToTheMirroredValueDoesNotWrite() {
        let model = make()
        settings.sounds = false  // changed behind the model's back

        model.setSounds(true)

        XCTAssertFalse(settings.sounds, "an unchanged value must not touch the store")
    }

    func testSetIdleUnloadMinutesPersistsAndFiresOnce() {
        let model = make()

        model.setIdleUnloadMinutes(0)
        model.setIdleUnloadMinutes(0)
        model.setIdleUnloadMinutes(60)

        XCTAssertEqual(model.idleUnloadMinutes, 60)
        XCTAssertEqual(settings.idleUnloadMinutes, 60)
        XCTAssertEqual(idleMinutes, [0, 60])
    }

    func testSetHistorySizePersistsAndFiresOnce() {
        let model = make()

        model.setHistorySize(30)
        model.setHistorySize(30)

        XCTAssertEqual(model.historySize, 30)
        XCTAssertEqual(settings.historySize, 30)
        XCTAssertEqual(historySizes, [30])
    }

    func testEachSetterLeavesTheOtherSettingsAlone() {
        let model = make()

        model.setHoldThreshold(0.8)

        XCTAssertEqual(hotkeys, [])
        XCTAssertEqual(idleMinutes, [])
        XCTAssertEqual(historySizes, [])
        XCTAssertEqual(settings.hotkey, .rightOption)
        XCTAssertEqual(settings.historySize, 10)
    }
}

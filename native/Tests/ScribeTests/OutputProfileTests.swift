import XCTest

final class OutputProfileTests: XCTestCase {
    private func profile(
        cleanup: Bool? = nil, voiceCommands: Bool? = nil, period: Bool = false, lower: Bool = false
    ) -> AppProfile {
        AppProfile(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", cleanup: cleanup,
                   voiceCommands: voiceCommands, stripTrailingPeriod: period, lowercaseFirst: lower)
    }

    func testNoProfileLeavesTextAlone() {
        XCTAssertEqual(OutputProfile.apply(nil, to: "Hello there."), "Hello there.")
        XCTAssertEqual(OutputProfile.apply(profile(), to: "Hello there."), "Hello there.")
    }

    func testStripsOneTrailingPeriodOnly() {
        let p = profile(period: true)
        XCTAssertEqual(OutputProfile.apply(p, to: "Hello there."), "Hello there")
        XCTAssertEqual(OutputProfile.apply(p, to: "Hello there"), "Hello there")
        XCTAssertEqual(OutputProfile.apply(p, to: "Hello there..."), "Hello there...")
        XCTAssertEqual(OutputProfile.apply(p, to: "Hello there?"), "Hello there?")
        XCTAssertEqual(OutputProfile.apply(p, to: "."), "")
        XCTAssertEqual(OutputProfile.apply(p, to: "See you at 5 p.m."), "See you at 5 p.m.")
        XCTAssertEqual(OutputProfile.apply(p, to: "Made in the U.S."), "Made in the U.S.")
        XCTAssertEqual(OutputProfile.apply(p, to: "Version 3.5."), "Version 3.5")
        XCTAssertEqual(OutputProfile.apply(p, to: "Plan A."), "Plan A")
        XCTAssertEqual(OutputProfile.apply(p, to: "And so on, etc."), "And so on, etc")
    }

    func testLowercasesOnlyASentenceInitialCapital() {
        let p = profile(lower: true)
        XCTAssertEqual(OutputProfile.apply(p, to: "Hello there."), "hello there.")
        XCTAssertEqual(OutputProfile.apply(p, to: "OK let's go"), "OK let's go")
        XCTAssertEqual(OutputProfile.apply(p, to: "iPhone is here"), "iPhone is here")
        XCTAssertEqual(OutputProfile.apply(p, to: "I think so"), "I think so")
        XCTAssertEqual(OutputProfile.apply(p, to: "I'm fine"), "I'm fine")
        XCTAssertEqual(OutputProfile.apply(p, to: "Hetzner is down"), "hetzner is down")
        XCTAssertEqual(OutputProfile.apply(p, to: "@Esteban can you"), "@Esteban can you")
        XCTAssertEqual(OutputProfile.apply(p, to: "/Users is a folder"), "/Users is a folder")
        XCTAssertEqual(OutputProfile.apply(p, to: ""), "")
    }

    func testAnIWithEdgePunctuationStaysCapitalised() {
        let p = profile(lower: true)
        XCTAssertEqual(OutputProfile.apply(p, to: "I, for one, agree"), "I, for one, agree")
        XCTAssertEqual(OutputProfile.apply(p, to: "I. Am. Done"), "I. Am. Done")
        XCTAssertEqual(OutputProfile.apply(p, to: "I\u{2019}m fine"), "I\u{2019}m fine")
    }

    func testLowercasesAfterAnOpeningMark() {
        let p = profile(lower: true)
        XCTAssertEqual(OutputProfile.apply(p, to: "¿Qué tal?"), "¿qué tal?")
        XCTAssertEqual(OutputProfile.apply(p, to: "¡Hola!"), "¡hola!")
        XCTAssertEqual(OutputProfile.apply(p, to: "«Hola»"), "«hola»")
        XCTAssertEqual(OutputProfile.apply(p, to: "Él dijo"), "él dijo")
        XCTAssertEqual(OutputProfile.apply(p, to: "\"Hello\" she said"), "\"hello\" she said")
        XCTAssertEqual(OutputProfile.apply(p, to: "¿OK?"), "¿OK?")
        XCTAssertEqual(OutputProfile.apply(p, to: "McDonald's is open"), "McDonald's is open")
        XCTAssertEqual(OutputProfile.apply(p, to: "3 apples"), "3 apples")
        XCTAssertEqual(OutputProfile.apply(p, to: "..."), "...")
    }

    func testBothRulesCompose() {
        XCTAssertEqual(OutputProfile.apply(profile(period: true, lower: true), to: "Sounds good."), "sounds good")
    }

    func testCleanupRuleOverridesTheGlobalToggleOnlyWhenSet() {
        XCTAssertTrue(OutputProfile.cleanupEnabled(nil, global: true))
        XCTAssertFalse(OutputProfile.cleanupEnabled(profile(), global: false))
        XCTAssertFalse(OutputProfile.cleanupEnabled(profile(cleanup: false), global: true))
        XCTAssertTrue(OutputProfile.cleanupEnabled(profile(cleanup: true), global: false))
    }

    func testVoiceCommandsRuleOverridesTheGlobalSwitchOnlyWhenSet() {
        XCTAssertTrue(OutputProfile.voiceCommandsEnabled(nil, global: true))
        XCTAssertFalse(OutputProfile.voiceCommandsEnabled(nil, global: false))
        XCTAssertTrue(OutputProfile.voiceCommandsEnabled(profile(), global: true))
        XCTAssertFalse(OutputProfile.voiceCommandsEnabled(profile(), global: false))
        XCTAssertFalse(OutputProfile.voiceCommandsEnabled(profile(voiceCommands: false), global: true))
        XCTAssertTrue(OutputProfile.voiceCommandsEnabled(profile(voiceCommands: true), global: false))
    }

    func testTheVoiceCommandsRuleIsIndependentOfTheCleanupRule() {
        let p = profile(cleanup: false, voiceCommands: true)
        XCTAssertFalse(OutputProfile.cleanupEnabled(p, global: true))
        XCTAssertTrue(OutputProfile.voiceCommandsEnabled(p, global: false))
    }

    func testWarmUpIgnoresTheVoiceCommandsRule() {
        XCTAssertFalse(OutputProfile.warmUpNeeded(global: false, profiles: [profile(voiceCommands: true)]))
    }

    func testWarmUpAtLaunchFollowsTheToggleOrAnAppThatTurnsCleanupOn() {
        XCTAssertTrue(OutputProfile.warmUpNeeded(global: true, profiles: []))
        XCTAssertFalse(OutputProfile.warmUpNeeded(global: false, profiles: []))
        XCTAssertFalse(OutputProfile.warmUpNeeded(global: false, profiles: [profile(), profile(cleanup: false)]))
        XCTAssertTrue(OutputProfile.warmUpNeeded(global: false, profiles: [profile(cleanup: false), profile(cleanup: true)]))
    }

    func testRulePickerTagsRoundTrip() {
        for setting in [nil, true, false] as [Bool?] {
            XCTAssertEqual(rule(fromTag: ruleTag(setting)), setting)
        }
        XCTAssertEqual(ruleChoices.map(\.label), ["Default", "On", "Off"])
    }

    func testProfileFromABundleReadsIdAndName() {
        // The test bundle itself is an application-like bundle with an identifier.
        let bundle = Bundle(for: OutputProfileTests.self)
        let made = appProfile(forBundleAt: bundle.bundleURL)
        XCTAssertEqual(made?.bundleID, bundle.bundleIdentifier)
        XCTAssertFalse(made?.appName.isEmpty ?? true)
        XCTAssertNil(appProfile(forBundleAt: FileManager.default.temporaryDirectory))
    }
}

final class AppProfileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeStore() -> AppProfileStore { AppProfileStore(fileURL: dir.appendingPathComponent("profiles.json")) }

    func testUpsertReplacesByBundleIdAndListsByName() {
        let store = makeStore()
        store.upsert(AppProfile(bundleID: "b", appName: "Zed"))
        store.upsert(AppProfile(bundleID: "a", appName: "Slack", stripTrailingPeriod: true))
        store.upsert(AppProfile(bundleID: "a", appName: "Slack", lowercaseFirst: true))

        XCTAssertEqual(store.all.map(\.appName), ["Slack", "Zed"])
        XCTAssertEqual(store.profile(for: "a"), AppProfile(bundleID: "a", appName: "Slack", lowercaseFirst: true))
        XCTAssertNil(store.profile(for: "zzz"))
        XCTAssertNil(store.profile(for: nil))
    }

    func testRemovePersistsAndReloads() {
        let store = makeStore()
        store.upsert(AppProfile(bundleID: "a", appName: "Slack", cleanup: false))
        store.upsert(AppProfile(bundleID: "b", appName: "Zed"))
        store.remove(bundleID: "b")
        XCTAssertEqual(store.all.map(\.bundleID), ["a"])

        let reopened = makeStore()
        XCTAssertEqual(reopened.profile(for: "a")?.cleanup, false)
        XCTAssertNil(reopened.profile(for: "b"))
    }

    func testOnChangeFiresAfterAWrite() {
        let store = makeStore()
        let fired = expectation(description: "onChange")
        store.onChange = { fired.fulfill() }
        store.upsert(AppProfile(bundleID: "a", appName: "Slack"))
        wait(for: [fired], timeout: 2)
    }

    @MainActor
    func testAddingAnAppAgainKeepsItsRules() async {
        let store = makeStore()
        let model = AppProfilesModel(store: store)
        model.upsert(AppProfile(bundleID: "a", appName: "Slack", stripTrailingPeriod: true))
        let shown = await eventually { model.profiles.count == 1 }
        XCTAssertTrue(shown)
        model.add(AppProfile(bundleID: "a", appName: "Slack"))
        XCTAssertEqual(store.profile(for: "a")?.stripTrailingPeriod, true)
        model.add(AppProfile(bundleID: "b", appName: "Zed"))
        let added = await eventually { model.profiles.count == 2 }
        XCTAssertTrue(added)
    }

    func testAProfileMissingASwitchStillLoads() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":1,"profiles":[{"bundleID":"a","appName":"Slack"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("profiles.json"))
        XCTAssertEqual(makeStore().profile(for: "a"), AppProfile(bundleID: "a", appName: "Slack"))
    }

    func testASwitchPresentInTheFileIsKept() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":1,"profiles":[{"bundleID":"a","appName":"Slack","cleanup":false,"lowercaseFirst":true}]}"#.utf8)
            .write(to: dir.appendingPathComponent("profiles.json"))
        XCTAssertEqual(
            makeStore().profile(for: "a"),
            AppProfile(bundleID: "a", appName: "Slack", cleanup: false, lowercaseFirst: true))
    }

    func testTheVoiceCommandsRuleSurvivesAReload() {
        let store = makeStore()
        store.upsert(AppProfile(bundleID: "a", appName: "Terminal", voiceCommands: false))
        store.upsert(AppProfile(bundleID: "b", appName: "Notes", voiceCommands: true))
        store.upsert(AppProfile(bundleID: "c", appName: "Zed"))
        XCTAssertEqual(store.all.count, 3, "the write has landed before the file is read back")

        let reopened = makeStore()
        XCTAssertEqual(reopened.profile(for: "a")?.voiceCommands, false)
        XCTAssertEqual(reopened.profile(for: "b")?.voiceCommands, true)
        XCTAssertNil(reopened.profile(for: "c")?.voiceCommands)
    }

    func testTheVoiceCommandsRuleIsReadFromTheFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":1,"profiles":[{"bundleID":"a","appName":"Terminal","voiceCommands":false}]}"#.utf8)
            .write(to: dir.appendingPathComponent("profiles.json"))
        XCTAssertEqual(
            makeStore().profile(for: "a"), AppProfile(bundleID: "a", appName: "Terminal", voiceCommands: false))
    }

    func testAProfileEncodesAndDecodesWithEveryRule() throws {
        let full = AppProfile(
            bundleID: "a", appName: "Slack", cleanup: false, voiceCommands: true, stripTrailingPeriod: true,
            lowercaseFirst: true)
        let bare = AppProfile(bundleID: "b", appName: "Zed")
        for profile in [full, bare] {
            let data = try JSONEncoder().encode(profile)
            XCTAssertEqual(try JSONDecoder().decode(AppProfile.self, from: data), profile)
        }
    }

    @MainActor
    func testProfilesModelMirrorsTheStore() async {
        let store = makeStore()
        let model = AppProfilesModel(store: store)
        XCTAssertEqual(model.profiles, [])
        model.upsert(AppProfile(bundleID: "a", appName: "Slack"))
        let shown = await eventually { model.profiles.map(\.bundleID) == ["a"] }
        XCTAssertTrue(shown)
        model.remove(AppProfile(bundleID: "a", appName: "Slack"))
        let gone = await eventually { model.profiles.isEmpty }
        XCTAssertTrue(gone)
    }
}

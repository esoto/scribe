import XCTest

final class CleanupModelCatalogTests: XCTestCase {
    private func downloaded(_ ids: Set<CleanupModelID>) -> (CleanupModelID) -> Bool {
        { ids.contains($0) }
    }

    func testSpecsCarryTheirRepoAndStopToken() {
        XCTAssertEqual(
            CleanupModelCatalog.gemma3.kind,
            .mlx(repoID: "mlx-community/gemma-3-4b-it-qat-4bit", extraEOSTokens: ["<end_of_turn>"]))
        XCTAssertEqual(
            CleanupModelCatalog.gemma4.kind,
            .mlx(repoID: "mlx-community/gemma-4-e4b-it-4bit", extraEOSTokens: ["<turn|>"]))
        XCTAssertEqual(CleanupModelCatalog.appleIntelligence.kind, .appleIntelligence)
        XCTAssertNil(CleanupModelCatalog.appleIntelligence.repoID)
        XCTAssertEqual(CleanupModelCatalog.all.map(\.id), CleanupModelID.allCases)
        for id in CleanupModelID.allCases {
            XCTAssertEqual(CleanupModelCatalog.spec(id).id, id)
        }
    }

    func testDefaultIsAlwaysADownloadableModel() {
        XCTAssertNotNil(CleanupModelCatalog.spec(CleanupModelCatalog.defaultID).repoID)
    }

    func testCustomPathOverridesEverything() {
        XCTAssertEqual(
            CleanupModelCatalog.resolve(
                stored: "gemma4", customPath: "/m", isDownloaded: downloaded([]),
                appleIntelligenceAvailable: true),
            .custom(path: "/m"))
    }

    func testStoredChoiceIsKept() {
        XCTAssertEqual(
            CleanupModelCatalog.resolve(
                stored: "gemma4", customPath: nil, isDownloaded: downloaded([]),
                appleIntelligenceAvailable: false),
            .model(.gemma4))
    }

    /// D2: an install that predates the picker already has Gemma 3 on disk —
    /// it must not silently start a multi-GB download of a new default.
    func testExistingInstallWithGemma3OnDiskStaysOnGemma3() {
        XCTAssertEqual(
            CleanupModelCatalog.resolve(
                stored: nil, customPath: nil, isDownloaded: downloaded([.gemma3]),
                appleIntelligenceAvailable: true),
            .model(.gemma3))
    }

    func testFreshInstallGetsTheDefault() {
        XCTAssertEqual(
            CleanupModelCatalog.resolve(
                stored: nil, customPath: nil, isDownloaded: downloaded([]),
                appleIntelligenceAvailable: true),
            .model(CleanupModelCatalog.defaultID))
    }

    func testUnknownStoredIDFallsBackToTheDefault() {
        XCTAssertEqual(
            CleanupModelCatalog.resolve(
                stored: "llama", customPath: nil, isDownloaded: downloaded([.gemma3]),
                appleIntelligenceAvailable: true),
            .model(CleanupModelCatalog.defaultID))
    }

    func testStoredAppleIntelligenceIsKeptWhileAvailable() {
        XCTAssertEqual(
            CleanupModelCatalog.resolve(
                stored: "appleIntelligence", customPath: nil, isDownloaded: downloaded([]),
                appleIntelligenceAvailable: true),
            .model(.appleIntelligence))
    }

    func testStoredAppleIntelligenceFallsBackWhenUnavailable() {
        let resolved = CleanupModelCatalog.resolve(
            stored: "appleIntelligence", customPath: nil, isDownloaded: downloaded([.gemma3]),
            appleIntelligenceAvailable: false)
        XCTAssertEqual(resolved, .model(CleanupModelCatalog.fallbackID(isDownloaded: downloaded([.gemma3]))))
        XCTAssertNotEqual(resolved, .model(.appleIntelligence))
    }

    func testFallbackPrefersADownloadedDefaultThenGemma3() {
        let defaultID = CleanupModelCatalog.defaultID
        XCTAssertEqual(CleanupModelCatalog.fallbackID(isDownloaded: downloaded([.gemma3])), .gemma3)
        XCTAssertEqual(CleanupModelCatalog.fallbackID(isDownloaded: downloaded([])), defaultID)
        XCTAssertEqual(
            CleanupModelCatalog.fallbackID(isDownloaded: downloaded([defaultID, .gemma3])), defaultID)
    }

    func testPromptSnapshotWithholdsGlossaryFromUnsafeModels() {
        let pair = ReplacementPair(original: "camel", replacement: "kamal", addedAt: Date(timeIntervalSince1970: 0))
        let snap = DictionarySnapshot(pairs: [pair], glossary: ["Kamal"])
        let custom = CleanupModelCatalog.promptSnapshot(snap, for: .custom(path: "/m"))
        XCTAssertEqual(custom.glossary, [])
        XCTAssertEqual(custom.pairs, [pair])
        for spec in CleanupModelCatalog.all {
            let out = CleanupModelCatalog.promptSnapshot(snap, for: .model(spec.id))
            XCTAssertEqual(out.glossary, spec.fidelitySafe ? ["Kamal"] : [], "\(spec.id)")
        }
    }

    func testSelectionStorageID() {
        XCTAssertEqual(CleanupModelCatalog.Selection.model(.gemma4).storageID, "gemma4")
        XCTAssertEqual(CleanupModelCatalog.Selection.custom(path: "/m").storageID, "custom")
        XCTAssertFalse(CleanupModelCatalog.Selection.custom(path: "/m").fidelitySafe)
    }

    func testStatusText() {
        XCTAssertEqual(CleanupModelCatalog.statusText(label: "Gemma 4 E4B", fraction: 0.427), "Downloading Gemma 4 E4B… 42%")
        XCTAssertEqual(CleanupModelCatalog.statusText(label: "Gemma 4 E4B", fraction: 1.0), "Loading Gemma 4 E4B…")
    }

    func testProgressRelayForwardsOnlyOnceAHandlerIsSet() {
        let relay = ProgressRelay()
        relay.report(model: "x", fraction: 0.5)  // no handler yet: dropped, no crash
        let got = Box<String>()
        relay.set { label, fraction in got.append("\(label):\(fraction)") }
        relay.report(model: "Gemma 4 E4B", fraction: 0.25)
        XCTAssertEqual(got.value, ["Gemma 4 E4B:0.25"])
    }

    func testMakeBackendBuildsTheRightKind() {
        let relay = ProgressRelay()
        XCTAssertTrue(CleanupModelCatalog.makeBackend(.model(.gemma4), relay: relay, onAppleIntelligenceLost: {}) is GemmaBackend)
        XCTAssertTrue(CleanupModelCatalog.makeBackend(.custom(path: "/m"), relay: relay, onAppleIntelligenceLost: {}) is GemmaBackend)
        if #available(macOS 26.0, *) {
            XCTAssertTrue(
                CleanupModelCatalog.makeBackend(.model(.appleIntelligence), relay: relay, onAppleIntelligenceLost: {})
                    is AppleIntelligenceBackend)
        }
    }
}

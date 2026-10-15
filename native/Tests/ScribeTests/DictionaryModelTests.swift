import XCTest

@MainActor
final class DictionaryModelTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var store: UserDictionaryStore!
    private var cleaner: FakeCleanupModelBackend!
    private var selection: CleanupModelCatalog.Selection!
    private var biasPushes: [[BiasTerm]]!
    private var logs: [String]!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
        store = UserDictionaryStore(fileURL: directory.appendingPathComponent("dictionary.json"))
        cleaner = FakeCleanupModelBackend()
        selection = .model(.gemma4)
        biasPushes = []
        logs = []
    }

    override func tearDown() {
        store.onChange = nil
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeModel() -> DictionaryModel {
        DictionaryModel(
            store: store, settings: settings,
            setBiasVocabulary: { [unowned self] in biasPushes.append($0) },
            currentCleaner: { [unowned self] in cleaner },
            currentSelection: { [unowned self] in selection },
            log: { [unowned self] in logs.append($0) })
    }

    private func pair(_ original: String, _ replacement: String) -> ReplacementPair {
        ReplacementPair(original: original, replacement: replacement, addedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Init

    func testInitMirrorsSettingsAndStore() {
        settings.dictionaryLearningEnabled = true
        settings.vocabularyBiasingEnabled = true
        store.addPair(original: "kube", replacement: "Kubernetes")
        _ = store.allPairs  // queue.sync: waits for the async add

        let model = makeModel()

        XCTAssertTrue(model.dictionaryLearningEnabled)
        XCTAssertTrue(model.vocabularyBiasingEnabled)
        XCTAssertTrue(store.learningEnabled)
        XCTAssertEqual(model.replacementPairs.map(\.original), ["kube"])
        XCTAssertEqual(model.dictionarySnapshot, store.snapshot)
        XCTAssertEqual(biasPushes.count, 1)
        XCTAssertTrue(biasPushes[0].contains { $0.text == "Kubernetes" })
    }

    func testInitPushesNoBiasVocabularyWhenBiasingIsOff() {
        _ = makeModel()
        XCTAssertEqual(biasPushes, [[]])
    }

    // MARK: - onChange

    func testStoreChangeRefreshesListsPushesBiasAndUpdatesSnapshot() async {
        settings.vocabularyBiasingEnabled = true
        let model = makeModel()
        biasPushes.removeAll()

        store.addPair(original: "kube", replacement: "Kubernetes")

        let refreshed = await eventually { model.replacementPairs.count == 1 }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.replacementPairs.first?.replacement, "Kubernetes")
        XCTAssertEqual(model.dictionarySnapshot, store.snapshot)
        XCTAssertTrue(biasPushes.last?.contains { $0.text == "Kubernetes" } ?? false)
        XCTAssertEqual(cleaner.dictionaries.count, 1)
    }

    func testUnchangedSnapshotDoesNotTouchTheCleaner() async {
        let model = makeModel()
        biasPushes.removeAll()

        model.applyDictionaryChange(store.snapshot)
        await model.rewarmTask?.value

        XCTAssertEqual(cleaner.dictionaries, [])
        XCTAssertEqual(cleaner.preloadCalls, 0)
        // The lists and bias vocabulary still refresh: the store notifies for sub-cap changes too.
        XCTAssertEqual(biasPushes.count, 1)
        XCTAssertEqual(logs, [])
    }

    func testChangedSnapshotPushesPromptSnapshotToTheCleaner() async {
        selection = .model(.gemma3)  // not fidelity-safe: the glossary must not reach its prompt
        let model = makeModel()
        let changed = DictionarySnapshot(pairs: [pair("kube", "Kubernetes")], glossary: ["Terraform"])

        model.applyDictionaryChange(changed)
        await model.rewarmTask?.value

        XCTAssertEqual(model.dictionarySnapshot, changed)
        XCTAssertEqual(
            cleaner.dictionaries, [DictionarySnapshot(pairs: changed.pairs, glossary: [])])
        XCTAssertEqual(logs, ["dictionary updated: 1 learned terms, 1 pairs"])
    }

    func testChangedSnapshotKeepsGlossaryForFidelitySafeModels() async {
        selection = .model(.gemma4)
        let model = makeModel()
        let changed = DictionarySnapshot(pairs: [], glossary: ["Terraform"])

        model.applyDictionaryChange(changed)
        await model.rewarmTask?.value

        XCTAssertEqual(cleaner.dictionaries, [changed])
    }

    func testChangedSnapshotRewarmsOnlyAResidentCleaner() async {
        cleaner.loaded = true
        let model = makeModel()

        model.applyDictionaryChange(DictionarySnapshot(pairs: [pair("a", "b")], glossary: []))
        await model.rewarmTask?.value

        XCTAssertEqual(cleaner.preloadCalls, 1)
        // setDictionary must land before the warm-prefix rebuild.
        XCTAssertEqual(cleaner.events, ["setDictionary", "preload"])
    }

    func testChangedSnapshotDoesNotForceLoadAColdCleaner() async {
        cleaner.loaded = false
        let model = makeModel()

        model.applyDictionaryChange(DictionarySnapshot(pairs: [pair("a", "b")], glossary: []))
        await model.rewarmTask?.value

        XCTAssertEqual(cleaner.preloadCalls, 0)
    }

    func testRewarmSkipsACleanerThatWasReplacedWhileChecking() async {
        cleaner.loaded = true
        let replacement = FakeCleanupModelBackend(loaded: true)
        let model = makeModel()

        model.applyDictionaryChange(DictionarySnapshot(pairs: [pair("a", "b")], glossary: []))
        // The switch commits before the re-warm task resumes: the captured cleaner is stale.
        let stale = cleaner!
        cleaner = replacement
        await model.rewarmTask?.value

        XCTAssertEqual(stale.preloadCalls, 0, "re-warming a replaced cleaner would resurrect an orphan")
        XCTAssertEqual(replacement.preloadCalls, 0)
    }

    // MARK: - Toggles

    func testSetVocabularyBiasingOffPushesAnEmptyVocabulary() {
        settings.vocabularyBiasingEnabled = true
        let model = makeModel()
        biasPushes.removeAll()

        model.setVocabularyBiasing(false)

        XCTAssertFalse(model.vocabularyBiasingEnabled)
        XCTAssertFalse(settings.vocabularyBiasingEnabled)
        XCTAssertEqual(biasPushes, [[]])
    }

    func testSetVocabularyBiasingOnPushesTheCuratedVocabulary() {
        let model = makeModel()
        biasPushes.removeAll()

        model.setVocabularyBiasing(true)

        XCTAssertTrue(model.vocabularyBiasingEnabled)
        XCTAssertTrue(settings.vocabularyBiasingEnabled)
        XCTAssertEqual(biasPushes.count, 1)
        XCTAssertFalse(biasPushes[0].isEmpty)
    }

    func testSetDictionaryLearningWritesStoreAndSettings() {
        let model = makeModel()
        XCTAssertFalse(store.learningEnabled)

        model.setDictionaryLearning(true)

        XCTAssertTrue(model.dictionaryLearningEnabled)
        XCTAssertTrue(store.learningEnabled)
        XCTAssertTrue(settings.dictionaryLearningEnabled)

        model.setDictionaryLearning(false)

        XCTAssertFalse(model.dictionaryLearningEnabled)
        XCTAssertFalse(store.learningEnabled)
        XCTAssertFalse(settings.dictionaryLearningEnabled)
    }

    // MARK: - refreshDictionaryState / biasVocabulary

    func testRefreshDictionaryStateRereadsTheLists() {
        let model = makeModel()
        store.onChange = nil  // isolate the explicit refresh from the onChange hop
        store.addPair(original: "kube", replacement: "Kubernetes")
        _ = store.allPairs
        XCTAssertEqual(model.replacementPairs, [])

        model.refreshDictionaryState()

        XCTAssertEqual(model.replacementPairs.map(\.original), ["kube"])
    }

    func testBiasVocabularyIsEmptyWhenBiasingIsDisabled() {
        settings.vocabularyBiasingEnabled = false
        XCTAssertEqual(DictionaryModel.biasVocabulary(from: store, settings: settings), [])
    }

    func testBiasVocabularyCarriesPairAliases() {
        settings.vocabularyBiasingEnabled = true
        store.addPair(original: "kube", replacement: "Kubernetes")
        _ = store.allPairs

        let terms = DictionaryModel.biasVocabulary(from: store, settings: settings)

        XCTAssertEqual(terms.first { $0.text == "Kubernetes" }?.aliases, ["kube"])
    }

    // MARK: - Store pass-throughs

    func testAddAndRemoveReplacementPairReachTheStore() async {
        let model = makeModel()

        model.addReplacementPair(original: "kube", replacement: "Kubernetes")
        let added = await eventually { model.replacementPairs.count == 1 }
        XCTAssertTrue(added)

        model.removeReplacementPair("kube")
        let removed = await eventually { model.replacementPairs.isEmpty }
        XCTAssertTrue(removed)
    }

    func testBindHeardWordAddsAnExactMatchPair() async {
        let model = makeModel()

        model.bindHeardWord("cooper netties", toReplacement: "Kubernetes")

        let bound = await eventually { model.replacementPairs.count == 1 }
        XCTAssertTrue(bound)
        XCTAssertEqual(model.replacementPairs.first?.original, "cooper netties")
        XCTAssertEqual(model.replacementPairs.first?.replacement, "Kubernetes")
    }

    func testClearLearnedTermsAndRemoveGlossaryTermReachTheStore() {
        let model = makeModel()
        model.removeGlossaryTerm("Terraform")
        model.clearLearnedTerms()
        // Nothing learned to remove; the calls must complete against the store queue without error.
        XCTAssertEqual(store.allGlossaryEntries, [])
    }

    func testIgnoreHeardWordReachesTheStore() {
        let model = makeModel()
        model.ignoreHeardWord("whatever")
        XCTAssertEqual(store.unmatchedHeardWords, [])
    }
}

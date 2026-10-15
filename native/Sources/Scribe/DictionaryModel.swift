import Foundation

/// The user dictionary as the menu and editor see it: published mirrors of the store plus the side effects of a
/// change (cleaner prompt, Parakeet bias vocabulary). The cleaner and its selection are read live through closures
/// so a model switch that lands between two dictionary edits is never missed.
@MainActor
final class DictionaryModel: ObservableObject {
    // Mirrors dictionary state for the menu and editor; counts/lastSeen can drift without a snapshot change.
    @Published private(set) var dictionarySnapshot: DictionarySnapshot
    @Published private(set) var dictionaryLearningEnabled: Bool
    @Published private(set) var vocabularyBiasingEnabled: Bool
    @Published private(set) var glossaryEntries: [GlossaryEntry]
    @Published private(set) var replacementPairs: [ReplacementPair]
    @Published private(set) var unmatchedHeardWords: [GlossaryEntry]

    /// The latest warm-prefix rebuild, so tests can await it.
    private(set) var rewarmTask: Task<Void, Never>?

    private let store: UserDictionaryStore
    private let settings: AppSettings
    private let setBiasVocabulary: ([BiasTerm]) -> Void
    private let currentCleaner: () -> any CleanupModelBackend
    private let currentSelection: () -> CleanupModelCatalog.Selection
    private let log: (String) -> Void

    init(
        store: UserDictionaryStore,
        settings: AppSettings,
        setBiasVocabulary: @escaping ([BiasTerm]) -> Void,
        currentCleaner: @escaping () -> any CleanupModelBackend,
        currentSelection: @escaping () -> CleanupModelCatalog.Selection,
        log: @escaping (String) -> Void
    ) {
        self.store = store
        self.settings = settings
        self.setBiasVocabulary = setBiasVocabulary
        self.currentCleaner = currentCleaner
        self.currentSelection = currentSelection
        self.log = log

        store.learningEnabled = settings.dictionaryLearningEnabled
        dictionaryLearningEnabled = settings.dictionaryLearningEnabled
        vocabularyBiasingEnabled = settings.vocabularyBiasingEnabled
        dictionarySnapshot = store.snapshot
        glossaryEntries = store.allGlossaryEntries
        replacementPairs = store.allPairs
        unmatchedHeardWords = store.unmatchedHeardWords
        // Bias vocab uses the full views, not the 30-term capped snapshot.
        setBiasVocabulary(Self.biasVocabulary(from: store, settings: settings))

        store.onChange = { [weak self] snapshot in
            // Fires on the store's queue; hop to the main actor.
            Task { @MainActor in
                self?.applyDictionaryChange(snapshot)
            }
        }
    }

    /// Applies a changed snapshot. Rebuilds the warm prefix only if the model is resident;
    /// a bare preload() would force-load ~2.5 GB.
    func applyDictionaryChange(_ snapshot: DictionarySnapshot) {
        // Store also notifies for sub-cap changes that move these lists without moving the snapshot.
        refreshDictionaryState()

        // Refresh bias vocab on any change: it reads the full views and the setter is cheap and load-free.
        setBiasVocabulary(Self.biasVocabulary(from: store, settings: settings))

        // Warm-prefix rebuild is costly; only do it when the prompt itself changes.
        guard snapshot != dictionarySnapshot else { return }
        dictionarySnapshot = snapshot
        let cleaner = currentCleaner()
        cleaner.setDictionary(CleanupModelCatalog.promptSnapshot(snapshot, for: currentSelection()))
        log("dictionary updated: \(snapshot.glossary.count) learned terms, \(snapshot.pairs.count) pairs")
        rewarmTask = Task { [weak self, cleaner] in
            if await cleaner.isLoaded, self?.currentCleaner() === cleaner {
                await cleaner.preload()
            }
        }
    }

    /// Re-reads state whose drift doesn't fire onChange (counts, lastSeen).
    func refreshDictionaryState() {
        glossaryEntries = store.allGlossaryEntries
        replacementPairs = store.allPairs
        unmatchedHeardWords = store.unmatchedHeardWords
    }

    /// Parakeet bias vocabulary from the full dictionary views plus the curated pack (when enabled).
    static func biasVocabulary(from dictionary: UserDictionaryStore, settings: AppSettings) -> [BiasTerm] {
        guard settings.vocabularyBiasingEnabled else { return [] }
        return BiasVocabularyBuilder.build(
            pairs: dictionary.allPairs,
            glossary: dictionary.allGlossaryEntries,
            includeCuratedPack: true)
    }

    /// Binds a heard mangling to an existing correction as an exact-match pair.
    func bindHeardWord(_ heard: String, toReplacement replacement: String) {
        store.addPair(original: heard, replacement: replacement)
    }

    func ignoreHeardWord(_ heard: String) {
        store.ignoreHeardWord(heard)
    }

    func setDictionaryLearning(_ on: Bool) {
        dictionaryLearningEnabled = on
        store.learningEnabled = on
        settings.dictionaryLearningEnabled = on
    }

    /// Toggles Parakeet vocabulary biasing and re-pushes the vocabulary (empty when off, so the CTC pass is skipped).
    func setVocabularyBiasing(_ on: Bool) {
        vocabularyBiasingEnabled = on
        settings.vocabularyBiasingEnabled = on
        setBiasVocabulary(Self.biasVocabulary(from: store, settings: settings))
    }

    func clearLearnedTerms() {
        store.clearLearned()
    }

    func addReplacementPair(original: String, replacement: String) {
        store.addPair(original: original, replacement: replacement)
    }

    func removeReplacementPair(_ original: String) {
        store.removePair(original: original)
    }

    func removeGlossaryTerm(_ term: String) {
        store.removeGlossaryTerm(term)
    }
}

import AppKit
import SwiftUI
import UserNotifications

/// Composition root: builds every collaborator and owns the app's mutable runtime state.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let history: History
    let pasteboard: MacPasteboard
    let paster: Paster
    let engines: [String: UnloadableEngine]
    let cleaner: GemmaBackend
    let idleTracker: IdleTracker
    let dictionary: UserDictionaryStore
    nonisolated let logger: FileLogger

    private(set) var pipeline: DictationPipeline!
    private var hotkeyMonitor: HotkeyMonitor!
    // Concrete so start() can prewarm its audio engine ahead of the first key-down.
    private var recorder: Recorder!
    private var engineSwitchTask: Task<Void, Never>?
    // Target of the in-flight engine switch; nil when none.
    private var pendingEngineName: String?

    @Published private(set) var state: PipelineState = .idle
    // Seeded from TCC probes in start(); the onboarding poll loop keeps it current.
    @Published var grants: GrantStatus = GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)
    @Published private(set) var activeEngineName: String
    @Published private(set) var cleanupEnabled: Bool
    @Published private(set) var microphoneUID: String?
    // Stable snapshot: enumerating in the menu body re-ran slow CoreAudio queries on every hover
    // and broke click registration on the submenu.
    @Published private(set) var microphones: [AudioInputDevice] = []
    @Published private(set) var launchAtLoginEnabled: Bool = LoginItem.isEnabled
    // Mirrors dictionary state for the menu and editor; counts/lastSeen can drift without a snapshot change.
    @Published private(set) var dictionarySnapshot: DictionarySnapshot = .empty
    @Published private(set) var dictionaryLearningEnabled: Bool
    @Published private(set) var vocabularyBiasingEnabled: Bool
    @Published private(set) var glossaryEntries: [GlossaryEntry] = []
    @Published private(set) var replacementPairs: [ReplacementPair] = []
    @Published private(set) var unmatchedHeardWords: [GlossaryEntry] = []

    private let pipelineConfig: PipelineConfig

    var glyph: String { glyphFor(state) }
    var grantsOk: Bool { grants.microphone && grants.accessibility && grants.inputMonitoring }

    init() {
        let defaults = UserDefaults.standard
        let settings = AppSettings(defaults: defaults)
        settings.importFromPythonConfigOnce()
        self.settings = settings

        let history = History(maxLen: settings.historySize)
        self.history = history

        let pasteboard = MacPasteboard()
        self.pasteboard = pasteboard
        self.paster = Paster(
            pasteboard: pasteboard,
            postCmdV: postCmdV,
            schedule: timerSchedule,
            restoreDelay: settings.restoreDelay
        )

        self.engines = [
            "parakeet": ParakeetEngine(),
            "whisper": WhisperEngine(),
        ]
        self.cleaner = GemmaBackend(customModelPath: settings.cleanupModelPath)
        self.idleTracker = IdleTracker(unloadAfterMinutes: settings.idleUnloadMinutes)
        self.logger = FileLogger()

        let dictionary = UserDictionaryStore()
        dictionary.learningEnabled = settings.dictionaryLearningEnabled
        self.dictionary = dictionary
        self.dictionaryLearningEnabled = settings.dictionaryLearningEnabled
        self.vocabularyBiasingEnabled = settings.vocabularyBiasingEnabled
        self.dictionarySnapshot = dictionary.snapshot
        self.glossaryEntries = dictionary.allGlossaryEntries
        self.replacementPairs = dictionary.allPairs
        self.unmatchedHeardWords = dictionary.unmatchedHeardWords
        // Before any preload, so the first warm-up uses the dictionary-augmented prompt.
        self.cleaner.setDictionary(dictionary.snapshot)
        // Bias vocab uses the full views, not the 30-term capped snapshot.
        (engines["parakeet"] as? ParakeetEngine)?.setBiasVocabulary(
            AppModel.biasVocabulary(from: dictionary, settings: settings))

        let startingEngine = engines[settings.engine] != nil ? settings.engine : "parakeet"
        self.activeEngineName = startingEngine
        self.cleanupEnabled = settings.cleanupEnabled
        self.microphoneUID = settings.microphoneUID

        self.pipelineConfig = PipelineConfig(
            holdThreshold: settings.holdThreshold,
            energyGate: settings.energyGate,
            minWords: settings.minWords,
            cleanupTimeout: settings.cleanupTimeout,
            lengthBand: settings.lengthBand,
            sampleRate: 16000.0
        )

        // All stored properties are initialized, so self can be captured by callbacks arriving off the main actor.
        let engine = self.engines[startingEngine]!
        let recorder = Recorder(sampleRate: pipelineConfig.sampleRate)
        recorder.setPreferredInput(uid: settings.microphoneUID)
        self.recorder = recorder
        self.pipeline = DictationPipeline(
            recorder: recorder,
            stt: engine,
            cleaner: self.cleaner,
            paster: self.paster,
            history: self.history,
            config: pipelineConfig,
            clock: { Date().timeIntervalSince1970 },
            onState: { [weak self] newState in
                Task { @MainActor in
                    self?.applyState(newState)
                }
            },
            onNotice: { [weak self] message in
                Task { @MainActor in
                    self?.notify(message)
                }
            },
            saveFailedAudio: { [weak self] pcm in
                Task { @MainActor in
                    self?.saveFailedAudio(pcm)
                }
            },
            cleanupEnabled: settings.cleanupEnabled,
            onLog: { [logger] line in logger.log(line) },
            // Store is thread-safe and observe() is fire-and-forget: no main-actor hop.
            onCleaned: { [dictionary] text in dictionary.observe(cleanedText: text) },
            replacementPairs: { [dictionary] in dictionary.snapshot.pairs }
        )

        dictionary.onChange = { [weak self] snapshot in
            // Fires on the store's queue; hop to the main actor.
            Task { @MainActor in
                self?.applyDictionaryChange(snapshot)
            }
        }

        self.hotkeyMonitor = HotkeyMonitor(
            key: settings.hotkey,
            onDown: { [weak self] in self?.handleKeyDown() },
            onUp: { [weak self] in self?.pipeline.keyUp() }
        )

        start()
    }

    // MARK: - Startup

    /// Installs the hotkey tap and starts the preload + idle-unload loops. Must run on main (CGEventTap).
    private func start() {
        // Cached TCC reads (no prompt), seeded early so the launch auto-open decision is correct.
        grants.microphone = TCC.microphoneGranted()
        grants.accessibility = TCC.accessibilityGranted()
        // Only prewarms if already granted; the prompt comes only from the onboarding Request button.
        prewarmRecorderIfGranted()

        hotkeyMonitor.onModifierEvent = { [logger] line in logger.log("tap: \(line)") }
        do {
            try hotkeyMonitor.install()
            grants.inputMonitoring = true
            logger.log("hotkey installed (key=\(settings.hotkey.rawValue))")
        } catch {
            logger.log("hotkey install failed: \(error)")
            grants.inputMonitoring = false
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [logger] granted, error in
            if let error {
                logger.log("notification authorization failed: \(error)")
            } else if !granted {
                logger.log("notification authorization denied")
            }
        }

        microphones = AudioDevices.inputDevices()
        AudioDevices.onDevicesChanged { [weak self] in
            guard let self else { return }
            // Republish only on a real change: CoreAudio's transient aggregates also fire the listener,
            // and a no-op republish closes the open Microphone submenu.
            let fresh = AudioDevices.inputDevices()
            if fresh != self.microphones {
                self.microphones = fresh
            }
        }

        preloadAtStartup()
        // Seed the idle tracker: due() requires a touch, so without this an unused launch pins ~3 GB forever.
        idleTracker.touch(now: ProcessInfo.processInfo.systemUptime)
        startIdleUnloadLoop()
    }

    private func preloadAtStartup() {
        let engine = engines[activeEngineName]
        let cleaner = self.cleaner
        let cleanupEnabled = self.cleanupEnabled
        let logger = self.logger
        Task {
            let t0 = Date()
            await engine?.preload()
            // The Swift cleaner is non-optional, so gate the preload on live cleanup-enabled state.
            if cleanupEnabled {
                await cleaner.preload()
            }
            let elapsed = Date().timeIntervalSince(t0)
            logger.log("models ready in \(String(format: "%.1f", elapsed))s")
        }
    }

    private func startIdleUnloadLoop() {
        guard idleTracker.enabled else { return }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.idleTracker.due(now: now) {
                    await self.unloadIdleModels()
                }
            }
        }
    }

    private func unloadIdleModels() async {
        var unloadedAny = false
        for engine in engines.values {
            if await engine.isLoaded {
                await engine.unload()
                unloadedAny = true
            }
        }
        if await cleaner.isLoaded {
            await cleaner.unload()
            unloadedAny = true
        }
        if unloadedAny {
            logger.log("idle — unloaded models to reclaim memory")
        }
    }

    // MARK: - Pipeline callbacks (always entered on @MainActor — see init())

    private func applyState(_ newState: PipelineState) {
        state = newState
        guard settings.sounds else { return }
        if newState == .recording {
            Sounds.play("Pop")
        } else if newState == .error {
            Sounds.play("Basso")
        }
    }

    private func notify(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "scribe"
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let logger = self.logger
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.log("notification delivery failed: \(message) (\(error))")
                print("[scribe] \(message)")
            }
        }
    }

    private func saveFailedAudio(_ pcm: [Float]) {
        let url = FileLogger.logsDirectory.appendingPathComponent("last_failed.wav")
        do {
            try WavWriter.write(pcm: pcm, sampleRate: UInt32(pipelineConfig.sampleRate), to: url)
        } catch {
            logger.log("failed to save failed-audio wav: \(error)")
        }
    }

    // MARK: - Hotkey wiring

    /// Touches the idle tracker, pre-warms engine + cleaner if unloaded, and forwards to the pipeline.
    /// Runs on main (CGEventTap callback).
    private func handleKeyDown() {
        idleTracker.touch(now: ProcessInfo.processInfo.systemUptime)

        if let engine = engines[activeEngineName] {
            let cleaner = self.cleaner
            let cleanupEnabled = self.cleanupEnabled
            // LazyModel coalesces concurrent loads; an in-flight load can't be cancelled.
            Task {
                if await !engine.isLoaded {
                    await engine.preload()
                }
                if cleanupEnabled, await !cleaner.isLoaded {
                    await cleaner.preload()
                }
            }
        }

        pipeline.keyDown()
    }

    // MARK: - Menu actions

    func switchEngine(to name: String) {
        guard let newEngine = engines[name] else { return }
        switch EngineSwitch.action(selecting: name, active: activeEngineName, pending: pendingEngineName) {
        case .ignore:
            return
        case .revert:
            // Re-selected the committed engine mid-preload: abandon the switch; the cancelled task unloads the superseded engine.
            engineSwitchTask?.cancel()
            engineSwitchTask = nil
            pendingEngineName = nil
        case .begin:
            engineSwitchTask?.cancel()
            pendingEngineName = name
            let previousEngine = engines[activeEngineName]
            let logger = self.logger
            engineSwitchTask = Task { [weak self] in
                await newEngine.preload()
                guard let self else { return }
                if Task.isCancelled {
                    // Superseded mid-preload: drop the load unless a newer selection landed back on this engine.
                    if EngineSwitch.shouldUnloadSuperseded(
                        name, active: self.activeEngineName, pending: self.pendingEngineName)
                    {
                        await newEngine.unload()
                    }
                    return
                }
                self.pipeline.setEngine(newEngine, name: name)
                self.activeEngineName = name
                self.pendingEngineName = nil
                self.settings.engine = name
                logger.log("switched engine to \(name)")
                await previousEngine?.unload()
            }
        }
    }

    /// Switches the capture device (nil = system default). The built-in mic avoids Bluetooth HFP renegotiation delay.
    func setMicrophone(uid: String?) {
        guard uid != microphoneUID else { return }
        microphoneUID = uid
        settings.microphoneUID = uid
        recorder.setPreferredInput(uid: uid)
        logger.log("microphone set to \(uid ?? "system default")")
        prewarmRecorderIfGranted()
    }

    func setCleanupEnabled(_ on: Bool) {
        cleanupEnabled = on
        pipeline.cleanupEnabled = on
        settings.cleanupEnabled = on
    }

    // MARK: - User dictionary

    /// Applies a changed snapshot. Rebuilds the warm prefix only if the model is resident;
    /// a bare preload() would force-load ~2.5 GB.
    private func applyDictionaryChange(_ snapshot: DictionarySnapshot) {
        // Store also notifies for sub-cap changes that move these lists without moving the snapshot.
        glossaryEntries = dictionary.allGlossaryEntries
        replacementPairs = dictionary.allPairs
        unmatchedHeardWords = dictionary.unmatchedHeardWords

        // Refresh bias vocab on any change: it reads the full views and the setter is cheap and load-free.
        (engines["parakeet"] as? ParakeetEngine)?.setBiasVocabulary(
            AppModel.biasVocabulary(from: dictionary, settings: settings))

        // Warm-prefix rebuild is costly; only do it when the prompt itself changes.
        guard snapshot != dictionarySnapshot else { return }
        dictionarySnapshot = snapshot
        cleaner.setDictionary(snapshot)
        logger.log(
            "dictionary updated: \(snapshot.glossary.count) learned terms, \(snapshot.pairs.count) pairs"
        )
        Task { [cleaner] in
            if await cleaner.isLoaded {
                await cleaner.preload()
            }
        }
    }

    /// Re-reads state whose drift doesn't fire onChange (counts, lastSeen).
    func refreshDictionaryState() {
        glossaryEntries = dictionary.allGlossaryEntries
        replacementPairs = dictionary.allPairs
        unmatchedHeardWords = dictionary.unmatchedHeardWords
    }

    /// Parakeet bias vocabulary from the full dictionary views plus the curated pack (when enabled).
    static func biasVocabulary(from dictionary: UserDictionaryStore, settings: AppSettings)
        -> [BiasTerm]
    {
        guard settings.vocabularyBiasingEnabled else { return [] }
        return BiasVocabularyBuilder.build(
            pairs: dictionary.allPairs,
            glossary: dictionary.allGlossaryEntries,
            includeCuratedPack: true)
    }

    /// Binds a heard mangling to an existing correction as an exact-match pair.
    func bindHeardWord(_ heard: String, toReplacement replacement: String) {
        dictionary.addPair(original: heard, replacement: replacement)
    }

    func ignoreHeardWord(_ heard: String) {
        dictionary.ignoreHeardWord(heard)
    }

    func setDictionaryLearning(_ on: Bool) {
        dictionaryLearningEnabled = on
        dictionary.learningEnabled = on
        settings.dictionaryLearningEnabled = on
    }

    /// Toggles Parakeet vocabulary biasing and re-pushes the vocabulary (empty when off, so the CTC pass is skipped).
    func setVocabularyBiasing(_ on: Bool) {
        vocabularyBiasingEnabled = on
        settings.vocabularyBiasingEnabled = on
        (engines["parakeet"] as? ParakeetEngine)?.setBiasVocabulary(
            AppModel.biasVocabulary(from: dictionary, settings: settings))
    }

    func clearLearnedTerms() {
        dictionary.clearLearned()
    }

    func addReplacementPair(original: String, replacement: String) {
        dictionary.addPair(original: original, replacement: replacement)
    }

    func removeReplacementPair(_ original: String) {
        dictionary.removePair(original: original)
    }

    func removeGlossaryTerm(_ term: String) {
        dictionary.removeGlossaryTerm(term)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try LoginItem.enable()
            } else {
                try LoginItem.disable()
            }
        } catch {
            logger.log("login item toggle failed: \(error)")
        }
        launchAtLoginEnabled = LoginItem.isEnabled
    }

    func copyToClipboard(_ text: String) {
        pasteboard.set(text)
    }

    // MARK: - Onboarding

    /// Live-activates the hotkey tap after Input Monitoring is granted. Must run on main.
    func activateHotkeyIfNeeded() {
        do {
            try hotkeyMonitor.reinstall()
            grants.inputMonitoring = true
        } catch {
            logger.log("hotkey reinstall failed: \(error)")
            grants.inputMonitoring = false
        }
    }

    /// Best-effort prewarm of the recorder's audio engine without starting capture. Guarded on the
    /// current grant so it never triggers the mic prompt; failure is non-fatal.
    func prewarmRecorderIfGranted() {
        guard grants.microphone else { return }
        do {
            try recorder.prewarm()
            logger.log("recorder prewarmed")
        } catch {
            logger.log("recorder prewarm failed: \(error)")
        }
    }
}

/// Scene id for the onboarding/Doctor window.
let onboardingWindowID = "onboarding"

@main
struct ScribeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // The content closure builds lazily, so the label's onAppear hosts the launch-time auto-open.
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("scribe setup", id: onboardingWindowID) {
            OnboardingWindow(model: model)
        }

        Window("scribe dictionary", id: dictionaryWindowID) {
            DictionaryWindow(model: model)
        }
    }
}

/// Menu bar glyph label; also the launch-time auto-open trigger for onboarding.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var didAutoOpen = false

    var body: some View {
        Text(model.glyph)
            .onAppear {
                guard !didAutoOpen else { return }
                didAutoOpen = true
                guard !OnboardingState.missing(model.grants).isEmpty else { return }
                openOnboarding(openWindow)
            }
    }
}

/// Brings scribe to the foreground and opens onboarding. LSUIElement apps don't auto-activate,
/// so windows can appear behind others.
func openOnboarding(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: onboardingWindowID)
}

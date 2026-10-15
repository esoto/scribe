import AppKit
import SwiftUI

/// Composition root: builds every collaborator, wires the sub-models to each other, and owns the state that
/// belongs to none of them (microphone, launch at login). The views observe the sub-models directly;
/// nothing is forwarded through here, so one model's write never rebuilds another's views.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let history: History
    let pasteboard: MacPasteboard
    let paster: Paster
    /// Parakeet Ultra download progress; same phase-1-init workaround as the cleanup controller's relay.
    private let sttProgressRelay = ProgressRelay()
    let idleTracker: IdleTracker
    let dictionary: UserDictionaryStore
    let dictionaryModel: DictionaryModel
    let permissions: PermissionsModel
    let dictation: DictationCoordinator
    let cleanupModels: CleanupModelController
    let engineController: EngineController
    nonisolated let logger: FileLogger

    @Published private(set) var cleanupEnabled: Bool
    @Published private(set) var microphoneUID: String?
    // Stable snapshot: enumerating in the menu body re-ran slow CoreAudio queries on every hover
    // and broke click registration on the submenu.
    @Published private(set) var microphones: [AudioInputDevice] = []
    @Published private(set) var launchAtLoginEnabled: Bool = LoginItem.isEnabled
    /// "Downloading Parakeet Ultra… NN%" while the STT model downloads (first launch after upgrade); nil otherwise.
    @Published private(set) var sttDownloadStatus: String?

    init() {
        let defaults = UserDefaults.standard
        let settings = AppSettings(defaults: defaults)
        settings.importFromPythonConfigOnce()
        self.settings = settings

        let history = History(maxLen: settings.historySize)
        self.history = history

        let pasteboard = MacPasteboard()
        self.pasteboard = pasteboard
        let paster = Paster(
            pasteboard: pasteboard,
            postCmdV: postCmdV,
            schedule: timerSchedule,
            restoreDelay: settings.restoreDelay
        )
        self.paster = paster

        // First, so the model loads below can report into scribe.log instead of stdout.
        let logger = FileLogger()
        self.logger = logger
        let log: @Sendable (String) -> Void = { logger.log($0) }

        let sttRelay = sttProgressRelay
        let engines: [String: UnloadableEngine] = [
            "parakeet": ParakeetEngine(
                onDownloadProgress: { sttRelay.report(model: "Parakeet Ultra", fraction: $0) }, onLog: log),
            "whisper": WhisperEngine(onLog: log),
        ]
        let idleTracker = IdleTracker(unloadAfterMinutes: settings.idleUnloadMinutes)
        self.idleTracker = idleTracker
        let dictionary = UserDictionaryStore()
        self.dictionary = dictionary

        // The sub-models call into each other (permissions ↔ coordinator, cleanup → coordinator); this ref
        // closes those loops once the coordinator exists.
        var lateDictation: DictationCoordinator!
        let engineController = EngineController(
            engines: engines,
            startingEngine: engines[settings.engine] != nil ? settings.engine : "parakeet",
            settings: settings,
            onEngineCommitted: { lateDictation.pipeline.setEngine($0, name: $1) },
            log: log)
        self.engineController = engineController
        let cleanupModels = CleanupModelController(
            settings: settings,
            makeBackend: { selection, relay, afmLost, onLog in
                CleanupModelCatalog.makeBackend(
                    selection, relay: relay, onAppleIntelligenceLost: afmLost, onLog: onLog)
            },
            computeStatuses: { CleanupModelController.computeModelStatuses(CleanupModelStore()) },
            deleteModel: { try CleanupModelStore().delete($0) },
            isAppleIntelligenceAvailable: { AppleIntelligence.isAvailable },
            appleIntelligenceUnavailableReason: { AppleIntelligence.unavailableReason },
            dictionarySnapshot: { dictionary.snapshot },
            onCleanerCommitted: { lateDictation.pipeline.setCleaner($0, name: $1) },
            notify: { lateDictation.notify($0) },
            touchIdle: { idleTracker.touch(now: ProcessInfo.processInfo.systemUptime) },
            log: log)
        self.cleanupModels = cleanupModels

        self.cleanupEnabled = settings.cleanupEnabled
        self.microphoneUID = settings.microphoneUID

        let config = PipelineConfig(
            holdThreshold: settings.holdThreshold,
            energyGate: settings.energyGate,
            minWords: settings.minWords,
            cleanupTimeout: settings.cleanupTimeout,
            lengthBand: settings.lengthBand,
            sampleRate: 16000.0
        )

        let engine = engineController.activeEngine
        let recorder = Recorder(sampleRate: config.sampleRate, engineControl: AVEngineControl(onLog: log))
        recorder.setPreferredInput(uid: settings.microphoneUID)

        let permissions = PermissionsModel(
            probe: LiveTCCProbe(),
            onMicrophoneGranted: { lateDictation.prewarmRecorderIfGranted() },
            onInputMonitoringGranted: { lateDictation.activateHotkeyIfNeeded() })
        let dictation = DictationCoordinator(
            recorder: recorder,
            pipelineConfig: config,
            hotkey: settings.hotkey,
            makePipeline: { sinks in
                let pipeline = DictationPipeline(
                    recorder: recorder,
                    stt: engine,
                    cleaner: cleanupModels.cleaner,
                    paster: GuardedPaster(
                        inner: paster,
                        accessibilityGranted: { TCC.accessibilityGranted() },
                        currentFrontmost: frontmostPID),
                    history: history,
                    config: config,
                    clock: { Date().timeIntervalSince1970 },
                    // keyDown runs on main (tap callback), so a direct read is safe.
                    frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                    onState: sinks.onState,
                    onNotice: sinks.onNotice,
                    saveFailedAudio: sinks.saveFailedAudio,
                    cleanupEnabled: settings.cleanupEnabled,
                    onLog: log,
                    // Store is thread-safe and observe() is fire-and-forget: no main-actor hop.
                    onCleaned: { [dictionary] text in dictionary.observe(cleanedText: text) },
                    replacementPairs: { [dictionary] in dictionary.allPairs },
                    onHint: sinks.onHint,
                    onPasted: sinks.onPasted
                )
                pipeline.setCleaner(cleanupModels.cleaner, name: cleanupModels.activeCleanupModel)
                return pipeline
            },
            makeHotkeyMonitor: { onDown, onUp in
                HotkeyMonitor(key: settings.hotkey, onDown: onDown, onUp: onUp)
            },
            notifier: UserNotifier(),
            playSound: { Sounds.play($0) },
            soundsEnabled: { settings.sounds },
            microphoneGranted: { permissions.grants.microphone },
            reportInputMonitoring: { permissions.setInputMonitoring($0) },
            log: log)
        lateDictation = dictation
        self.permissions = permissions
        self.dictation = dictation

        let parakeet = engines["parakeet"] as? ParakeetEngine
        self.dictionaryModel = DictionaryModel(
            store: dictionary, settings: settings,
            setBiasVocabulary: { parakeet?.setBiasVocabulary($0) },
            currentCleaner: { cleanupModels.cleaner },
            currentSelection: { cleanupModels.activeSelection },
            log: log)
        // Before any preload, so the first warm-up uses the dictionary-augmented prompt.
        cleanupModels.cleaner.setDictionary(
            CleanupModelCatalog.promptSnapshot(dictionary.snapshot, for: cleanupModels.activeSelection))

        // All stored properties are initialized, so self can be captured by callbacks arriving off the main actor.
        dictation.onKeyDown = { [weak self] in self?.prepareForKeyDown() }
        sttProgressRelay.set { [weak self] label, fraction in
            Task { @MainActor in
                self?.sttDownloadStatus = fraction < 1 ? CleanupModelCatalog.statusText(label: label, fraction: fraction) : nil
            }
        }

        start()
    }

    // MARK: - Startup

    /// Starts the coordinator (hotkey tap) and the preload + idle-unload loops. Must run on main (CGEventTap).
    private func start() {
        // last_failed.wav is for debugging a recent failure, not for keeping audio around.
        FileLogger.expireFailedAudio()
        dictation.start()

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
        permissions.startWatching()
    }

    private func preloadAtStartup() {
        let engine = engineController.activeEngine
        let cleanupModels = self.cleanupModels
        // Captured before the STT preload below: the controller re-checks it is still the current one afterwards.
        let cleaner = cleanupModels.cleaner
        let cleanupEnabled = self.cleanupEnabled
        let logger = self.logger
        Task {
            let t0 = Date()
            await engine.preload()
            let cleanupLoaded = await cleanupModels.preloadAtStartup(cleaner, enabled: cleanupEnabled)
            let sttLoaded = await engine.isLoaded
            logger.log(
                AppModel.startupLogLine(
                    sttLoaded: sttLoaded, cleanupLoaded: cleanupLoaded, elapsed: Date().timeIntervalSince(t0)))
        }
    }

    /// "models ready" must only be written when they are; the load errors themselves are logged where they happen.
    nonisolated static func startupLogLine(sttLoaded: Bool, cleanupLoaded: Bool, elapsed: Double) -> String {
        let took = String(format: "%.1f", elapsed)
        var failed: [String] = []
        if !sttLoaded { failed.append("transcription model") }
        if !cleanupLoaded { failed.append("cleanup model") }
        guard !failed.isEmpty else { return "models ready in \(took)s" }
        return "models not ready after \(took)s — \(failed.joined(separator: " and ")) failed to load"
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
        var unloadedAny = await engineController.unloadAll()
        if await cleanupModels.unloadIfResident() {
            unloadedAny = true
        }
        if unloadedAny {
            logger.log("idle — unloaded models to reclaim memory")
        }
    }

    // MARK: - Hotkey wiring

    /// The coordinator's key-down hook: touches the idle tracker and pre-warms engine + cleaner if unloaded.
    /// Runs on main (CGEventTap callback), before the coordinator arms the watchdog and starts recording.
    private func prepareForKeyDown() {
        idleTracker.touch(now: ProcessInfo.processInfo.systemUptime)
        cleanupModels.refreshAppleIntelligenceAvailability()
        // Deferred: a flip can reinstall the event tap, which must not happen inside the tap's own callback.
        Task { [weak self] in self?.permissions.refreshGrants() }

        let engine = engineController.activeEngine
        let cleanupModels = self.cleanupModels
        let cleaner = cleanupModels.cleaner
        let cleanupEnabled = self.cleanupEnabled
        // LazyModel coalesces concurrent loads; an in-flight load can't be cancelled.
        Task {
            if await !engine.isLoaded {
                await engine.preload()
            }
            await cleanupModels.warmUpIfNeeded(cleaner, enabled: cleanupEnabled)
        }
    }

    // MARK: - Menu actions

    func switchEngine(to name: String) {
        engineController.switchEngine(to: name)
    }

    /// Switches the capture device (nil = system default). The built-in mic avoids Bluetooth HFP renegotiation delay.
    func setMicrophone(uid: String?) {
        guard uid != microphoneUID else { return }
        microphoneUID = uid
        settings.microphoneUID = uid
        dictation.selectMicrophone(uid: uid)
    }

    func setCleanupEnabled(_ on: Bool) {
        cleanupEnabled = on
        dictation.setCleanupEnabled(on)
        settings.cleanupEnabled = on
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
}

/// Same phase-1-init workaround as ProgressRelay, for the AFM-lost signal.
final class AppleIntelligenceLostHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    func set(_ handler: @escaping () -> Void) { lock.withLock { self.handler = handler } }
    func fire() { let h = lock.withLock { handler }; h?() }
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
            OnboardingWindow(permissions: model.permissions, settings: model.settings)
        }

        Window("scribe dictionary", id: dictionaryWindowID) {
            DictionaryWindow(model: model.dictionaryModel)
        }

        Window("scribe models", id: modelsWindowID) {
            ModelsWindow(model: model.cleanupModels)
        }
    }
}

/// Menu bar glyph label; also the launch-time auto-open trigger for onboarding.
private struct MenuBarLabel: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var dictation: DictationCoordinator
    @ObservedObject var cleanupModels: CleanupModelController
    @Environment(\.openWindow) private var openWindow
    @State private var didAutoOpen = false

    init(model: AppModel) {
        self.permissions = model.permissions
        self.dictation = model.dictation
        self.cleanupModels = model.cleanupModels
    }

    var body: some View {
        Text(
            menuBarGlyph(
                dictation.state, progress: cleanupModels.cleanupModelProgress, needsAttention: !permissions.grantsOk))
            .onAppear {
                guard !didAutoOpen else { return }
                didAutoOpen = true
                guard !OnboardingState.missing(permissions.grants).isEmpty else { return }
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

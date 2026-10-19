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
    /// Enhance Audio's model download progress; same workaround.
    private let enhancerProgressRelay = ProgressRelay()
    let idleTracker: IdleTracker
    let dictionary: UserDictionaryStore
    let dictionaryModel: DictionaryModel
    let permissions: PermissionsModel
    let dictation: DictationCoordinator
    let settingsModel: SettingsModel
    let cleanupModels: CleanupModelController
    let engineController: EngineController
    let enhancerLifecycle: EnhanceAudioLifecycle
    nonisolated let logger: FileLogger

    @Published private(set) var cleanupEnabled: Bool
    @Published private(set) var enhanceAudioEnabled: Bool
    @Published private(set) var microphoneUID: String?
    // Stable snapshot: enumerating in the menu body re-ran slow CoreAudio queries on every hover
    // and broke click registration on the submenu.
    @Published private(set) var microphones: [AudioInputDevice] = []
    @Published private(set) var launchAtLoginEnabled: Bool = LoginItem.isEnabled
    /// "Downloading Parakeet Ultra… NN%" while the STT model downloads (first launch after upgrade); nil otherwise.
    @Published private(set) var sttDownloadStatus: String?
    /// "Downloading Enhance Audio… NN%" while its model downloads (first use after the toggle goes on); nil otherwise.
    @Published private(set) var enhancerDownloadStatus: String?
    /// True until the launch preload ends. The download statuses cover only part of it: a load from disk reports nothing.
    @Published private(set) var startupPreloadInFlight = true

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

        // Before any download: ModelHub resolves the revision when a download starts.
        LocalVQEEnhancer.pinModelRevision()
        let sttRelay = sttProgressRelay
        let engines: [String: UnloadableEngine] = [
            "parakeet": ParakeetEngine(
                onDownloadProgress: { sttRelay.report(model: "Parakeet Ultra", fraction: $0) }, onLog: log),
            "whisper": WhisperEngine(onLog: log),
        ]
        let enhancerRelay = enhancerProgressRelay
        let enhancer = LocalVQEEnhancer(
            onDownloadProgress: { enhancerRelay.report(model: "Enhance Audio", fraction: $0) }, onLog: log)
        self.enhancerLifecycle = EnhanceAudioLifecycle(enhancer: enhancer, enabled: settings.enhanceAudioEnabled)
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
        self.enhanceAudioEnabled = settings.enhanceAudioEnabled
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
            notificationAuthorizer: LiveNotificationAuthorizer(log: log),
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
                    enhancer: enhancer,
                    enhanceAudioEnabled: settings.enhanceAudioEnabled,
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
            makeHotkeyMonitor: { key, onDown, onUp in
                HotkeyMonitor(key: key, onDown: onDown, onUp: onUp)
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
        self.settingsModel = SettingsModel(
            settings: settings,
            onHotkeyChanged: { dictation.setHotkey($0) },
            onHoldThresholdChanged: { dictation.pipeline.setHoldThreshold($0) },
            onIdleMinutesChanged: { idleTracker.setUnloadAfterMinutes($0) },
            onHistorySizeChanged: { history.setMaxLen($0) },
            onRestoreDelayChanged: { paster.setRestoreDelay($0) })

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
        enhancerProgressRelay.set { [weak self] label, fraction in
            Task { @MainActor in
                self?.enhancerDownloadStatus = fraction < 1 ? CleanupModelCatalog.statusText(label: label, fraction: fraction) : nil
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
            // and a no-op republish rebuilds the open menu and the Settings window's microphone picker.
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
        Task { [weak self] in
            let t0 = Date()
            await engine.preload()
            let cleanupLoaded = await cleanupModels.preloadAtStartup(cleaner, enabled: cleanupEnabled)
            let sttLoaded = await engine.isLoaded
            self?.startupPreloadInFlight = false
            logger.log(
                AppModel.startupLogLine(
                    sttLoaded: sttLoaded, cleanupLoaded: cleanupLoaded, elapsed: Date().timeIntervalSince(t0)))
            // After the line above: an optional experiment must not hold up "models ready" or the setup window.
            await self?.enhancerLifecycle.warmUp().value
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

    /// Runs even while unloading is off: `due` answers false then, and a later Settings change takes effect
    /// without a relaunch.
    private func startIdleUnloadLoop() {
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
        if await enhancerLifecycle.unloadIfResident() {
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
        // Separate from the STT warm-up: enhance skips itself while cold, so it must not queue behind it.
        enhancerLifecycle.warmUp()
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

    func setEnhanceAudio(_ on: Bool) {
        enhanceAudioEnabled = on
        dictation.setEnhanceAudioEnabled(on)
        settings.enhanceAudioEnabled = on
        enhancerLifecycle.setEnabled(on)
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
    @NSApplicationDelegateAdaptor(ScribeAppDelegate.self) private var appDelegate
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
            OnboardingWindow(
                permissions: model.permissions, model: model, cleanupModels: model.cleanupModels,
                dictation: model.dictation, settingsModel: model.settingsModel)
        }

        Window("scribe dictionary", id: dictionaryWindowID) {
            DictionaryWindow(model: model.dictionaryModel, cleanupModels: model.cleanupModels)
        }

        Window("scribe settings", id: settingsWindowID) {
            SettingsWindow(model: model)
        }
        .commands { SettingsCommand() }
    }
}

/// The menu bar menu's ⌘, only fires while that menu is open. With a scribe window frontmost the app is a
/// regular app with a main menu, and ⌘, belongs there.
private struct SettingsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openSettingsWindow(openWindow) }
                .keyboardShortcut(",")
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
                dictation.state, progress: cleanupModels.cleanupModelProgress, needsAttention: !permissions.grantsOk)
        )
        // The glyph alone reads as "white bullet" or "warning sign"; the value says what it means.
        .accessibilityLabel("scribe")
        .accessibilityValue(
            glyphAccessibilityValue(
                dictation.state, progress: cleanupModels.cleanupModelProgress, needsAttention: !permissions.grantsOk)
        )
        .onAppear {
            guard !didAutoOpen else { return }
            didAutoOpen = true
            guard !OnboardingState.missing(permissions.grants).isEmpty else { return }
            openOnboarding(openWindow)
        }
        .onReceive(NotificationCenter.default.publisher(for: .scribeReopen)) { _ in
            openOnboarding(openWindow)
        }
    }
}

extension Notification.Name {
    static let scribeReopen = Notification.Name("dev.esoto.scribe.reopen")
}

/// With the menu bar item hidden behind the notch, launching scribe again from Spotlight or Finder did nothing.
/// Only a view can reach `openWindow`, so this posts and `MenuBarLabel` opens Setup.
final class ScribeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if OnboardingState.shouldOpenSetupOnReopen(hasVisibleWindows: hasVisibleWindows) {
            NotificationCenter.default.post(name: .scribeReopen, object: nil)
        }
        return false
    }
}

/// Brings scribe to the foreground and opens onboarding. LSUIElement apps don't auto-activate,
/// so windows can appear behind others.
func openOnboarding(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: onboardingWindowID)
}

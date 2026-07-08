import SwiftUI
import UserNotifications

/// Composition root: builds every collaborator wired in Tasks 2-12 and owns
/// the app's mutable runtime state.
///
/// Ported from the composition-root half of `scribe.app.main`
/// (src/scribe/app.py) — model preload, idle-unload loop, engine switching,
/// failed-audio capture, and notification delivery all live here, adapted to
/// SwiftUI/MenuBarExtra + Swift concurrency instead of rumps + threads.
@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let history: History
    let pasteboard: MacPasteboard
    let paster: Paster
    let engines: [String: UnloadableEngine]
    let cleaner: GemmaBackend
    let idleTracker: IdleTracker
    nonisolated let logger: FileLogger

    private(set) var pipeline: DictationPipeline!
    private var hotkeyMonitor: HotkeyMonitor!

    @Published private(set) var state: PipelineState = .idle
    // Task 14's onboarding probes will keep this current for mic/accessibility.
    @Published var grants: GrantStatus = GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)
    @Published private(set) var activeEngineName: String
    @Published private(set) var cleanupEnabled: Bool
    @Published private(set) var launchAtLoginEnabled: Bool = LoginItem.isEnabled
    @Published var showDoctor: Bool = false

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
        self.cleaner = GemmaBackend()
        self.idleTracker = IdleTracker(unloadAfterMinutes: settings.idleUnloadMinutes)
        self.logger = FileLogger()

        let startingEngine = engines[settings.engine] != nil ? settings.engine : "parakeet"
        self.activeEngineName = startingEngine
        self.cleanupEnabled = settings.cleanupEnabled

        self.pipelineConfig = PipelineConfig(
            holdThreshold: settings.holdThreshold,
            energyGate: settings.energyGate,
            minWords: settings.minWords,
            cleanupTimeout: settings.cleanupTimeout,
            lengthBand: settings.lengthBand,
            sampleRate: 16000.0
        )

        // Phase-1 initialization (all stored properties above) is complete —
        // `self` may now be captured, so the pipeline's callbacks (which
        // arrive off the main actor, from DictationPipeline's serial worker)
        // can hop back to it.
        let engine = self.engines[startingEngine]!
        self.pipeline = DictationPipeline(
            recorder: Recorder(sampleRate: pipelineConfig.sampleRate),
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
            cleanupEnabled: settings.cleanupEnabled
        )

        self.hotkeyMonitor = HotkeyMonitor(
            key: settings.hotkey,
            onDown: { [weak self] in self?.handleKeyDown() },
            onUp: { [weak self] in self?.pipeline.keyUp() }
        )

        start()
    }

    // MARK: - Startup

    /// Installs the hotkey tap, requests notification authorization, and
    /// kicks off the background preload + idle-unload loops. Called once
    /// from `init()`, on the main thread (required for the CGEventTap).
    private func start() {
        do {
            try hotkeyMonitor.install()
            grants.inputMonitoring = true
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

        preloadAtStartup()
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
            // Mirrors the Python reference (src/scribe/app.py's load_models),
            // which only constructs/preloads the cleaner when cleanup is
            // enabled — the Swift cleaner is a non-optional stored property,
            // so gate the preload on the live cleanup-enabled state instead.
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

    /// Touches the idle tracker, pre-warms the active engine + cleaner if an
    /// idle unload dropped them, and forwards to the pipeline. Runs on the
    /// main thread — `HotkeyMonitor` invokes `onDown`/`onUp` synchronously
    /// from the CGEventTap callback on the run loop `install()` was called
    /// from (main, per Task 13's wiring contract).
    private func handleKeyDown() {
        idleTracker.touch(now: ProcessInfo.processInfo.systemUptime)

        if let engine = engines[activeEngineName] {
            let cleaner = self.cleaner
            let cleanupEnabled = self.cleanupEnabled
            Task.detached {
                if await !engine.isLoaded {
                    await engine.preload()
                }
                // Gated on cleanup-enabled, same as preloadAtStartup() —
                // see the comment there for the Python-reference rationale.
                if cleanupEnabled, await !cleaner.isLoaded {
                    await cleaner.preload()
                }
            }
        }

        pipeline.keyDown()
    }

    // MARK: - Menu actions

    func switchEngine(to name: String) {
        guard name != activeEngineName, let newEngine = engines[name] else { return }
        let previousName = activeEngineName
        let previousEngine = engines[previousName]
        let logger = self.logger
        Task { [weak self] in
            await newEngine.preload()
            guard let self else { return }
            self.pipeline.setEngine(newEngine, name: name)
            self.activeEngineName = name
            self.settings.engine = name
            logger.log("switched engine to \(name)")
            await previousEngine?.unload()
        }
    }

    func setCleanupEnabled(_ on: Bool) {
        cleanupEnabled = on
        pipeline.cleanupEnabled = on
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

    func openDoctor() {
        showDoctor = true
    }
}

@main
struct ScribeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra(model.glyph) {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

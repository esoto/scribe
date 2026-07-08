import AppKit
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
    // Held concretely (not just as the pipeline's private RecorderLike) so
    // start() and prewarmRecorderIfGranted() can prewarm its audio engine
    // ahead of the first key-down — see Recorder.prewarm().
    private var recorder: Recorder!

    @Published private(set) var state: PipelineState = .idle
    // Seeded from TCC probes in start(); the onboarding window's 2 s poll
    // loop (OnboardingWindow.swift) keeps this current thereafter, and
    // live-activates the hotkey via activateHotkeyIfNeeded() on an
    // inputMonitoring false→true flip.
    @Published var grants: GrantStatus = GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)
    @Published private(set) var activeEngineName: String
    @Published private(set) var cleanupEnabled: Bool
    @Published private(set) var launchAtLoginEnabled: Bool = LoginItem.isEnabled

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
        let recorder = Recorder(sampleRate: pipelineConfig.sampleRate)
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
        // Microphone/accessibility probes are synchronous reads of the
        // cached TCC status (no prompt) — seed them up front so the
        // launch-time auto-open decision (OnboardingState.missing) is
        // correct even before the onboarding window's poll loop starts.
        grants.microphone = TCC.microphoneGranted()
        grants.accessibility = TCC.accessibilityGranted()
        // Never triggers the TCC prompt itself — only fires when the probe
        // above already reports granted (e.g. a prior run completed
        // onboarding). The prompt only ever comes from the onboarding
        // window's own Request button (TCC.requestMicrophone()).
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

    // MARK: - Onboarding

    /// Live-activates the hotkey tap right after the user grants Input
    /// Monitoring from the onboarding window — no app restart required.
    /// Called from `OnboardingWindow`'s poll loop on an inputMonitoring
    /// false→true flip. Must run on the main thread, same contract as
    /// `HotkeyMonitor.install`/`reinstall`; `AppModel` being `@MainActor`
    /// guarantees that for every call site.
    func activateHotkeyIfNeeded() {
        do {
            try hotkeyMonitor.reinstall()
            grants.inputMonitoring = true
        } catch {
            logger.log("hotkey reinstall failed: \(error)")
            grants.inputMonitoring = false
        }
    }

    /// Best-effort starts the recorder's audio engine (without arming it) —
    /// see `Recorder.prewarm()`. Called from `start()` at launch when the
    /// microphone TCC probe already reports granted, and from
    /// `OnboardingWindow`'s poll loop right after it observes a
    /// microphone false→true flip, so a dictation immediately following
    /// either onboarding step doesn't pay the engine's cold-start latency
    /// on its first syllable. Guards on the current grant so it can never
    /// itself trigger the OS microphone prompt — that only ever comes from
    /// the onboarding window's Request button. Failure is logged, never
    /// fatal: the engine still starts lazily on the next real `arm()`.
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

/// Scene id for the onboarding/Doctor window, shared between the
/// launch-time auto-open hook and the menu's "Setup / Doctor…" item.
let onboardingWindowID = "onboarding"

@main
struct ScribeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // `MenuBarExtra`'s content closure (the menu itself) only
            // builds lazily when the user opens it, so it can't host a
            // launch-time hook. The label, in contrast, is resolved
            // immediately — it's what's drawn in the menu bar — so its
            // `onAppear` is where we auto-open onboarding when a
            // permission is missing at launch.
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("scribe setup", id: onboardingWindowID) {
            OnboardingWindow(model: model)
        }
    }
}

/// Menu bar glyph label. Doubles as the launch-time auto-open trigger for
/// the onboarding window (see the comment on `ScribeApp.body`).
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

/// Brings scribe to the foreground and opens the onboarding window.
/// `MenuBarExtra` apps are `LSUIElement` (no Dock icon, no automatic
/// activation), so opened windows can otherwise appear behind other apps.
func openOnboarding(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: onboardingWindowID)
}

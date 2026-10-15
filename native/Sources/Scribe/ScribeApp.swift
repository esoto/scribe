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
    private(set) var cleaner: any CleanupModelBackend
    private var activeSelection: CleanupModelCatalog.Selection
    private let progressRelay = ProgressRelay()
    /// Parakeet Ultra download progress; same phase-1-init workaround as progressRelay.
    private let sttProgressRelay = ProgressRelay()
    private var cleanupSwitchTask: Task<Void, Never>?
    /// True while a cleanup model is downloading/loading on purpose (startup
    /// preload or a picker switch) — gates the progress status line so a
    /// late progress tick can't resurrect "Loading…" after commit.
    private var cleanupLoadInFlight = false
    /// True once this switch reported progress below 1, so the completion
    /// notification fires only when something really downloaded.
    private var cleanupModelDidDownload = false
    /// Set once the AFM-lost fallback has fired; stops every key-down's
    /// availability refresh from re-notifying and retrying a fallback that
    /// already ran (or failed to load). Reset when AFM is available again.
    private var didFallbackFromAppleIntelligence = false
    private let appleIntelligenceLost: AppleIntelligenceLostHandoff
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
    private var errorRevert: Task<Void, Never>?
    // Seeded from TCC probes in start(); refreshGrants() keeps it current.
    @Published private(set) var grants: GrantStatus = GrantStatus(microphone: false, accessibility: false, inputMonitoring: false)
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
    @Published private(set) var activeCleanupModel: String
    @Published private(set) var pendingCleanupModel: String?
    @Published private(set) var cleanupModelStatus: String?
    /// Download fraction (0…1) while a cleanup model downloads; nil otherwise.
    @Published private(set) var cleanupModelProgress: Double?
    /// "Downloading Parakeet Ultra… NN%" while the STT model downloads (first launch after upgrade); nil otherwise.
    @Published private(set) var sttDownloadStatus: String?
    @Published private(set) var appleIntelligenceAvailable: Bool
    @Published private(set) var appleIntelligenceUnavailableReason: String?
    @Published private(set) var modelStatuses: [CleanupModelID: CleanupModelStore.Status] = [:]

    var activeCleanupFidelitySafe: Bool { activeSelection.fidelitySafe }

    private let pipelineConfig: PipelineConfig

    var glyph: String { menuBarGlyph(state, progress: cleanupModelProgress, needsAttention: !grantsOk) }
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

        let sttRelay = sttProgressRelay
        self.engines = [
            "parakeet": ParakeetEngine(onDownloadProgress: { sttRelay.report(model: "Parakeet Ultra", fraction: $0) }),
            "whisper": WhisperEngine(),
        ]
        let store = CleanupModelStore()
        let statuses = AppModel.computeModelStatuses(store)
        let afmAvailable = AppleIntelligence.isAvailable
        let selection = CleanupModelCatalog.resolve(
            stored: settings.cleanupModel, customPath: settings.cleanupModelPath,
            isDownloaded: { statuses[$0]?.isDownloaded ?? false },
            appleIntelligenceAvailable: afmAvailable)
        // D2: pin the resolved choice so a later default flip never moves
        // this install (and never triggers a surprise download). Only when
        // nothing is stored: a transient AFM `.modelNotReady` makes resolve()
        // return a Gemma fallback, and pinning that would permanently
        // overwrite the user's stored "appleIntelligence".
        if settings.cleanupModel == nil, case .model(let id) = selection {
            settings.cleanupModel = id.rawValue
        }
        self.activeSelection = selection
        self.activeCleanupModel = selection.storageID
        self.modelStatuses = statuses
        self.appleIntelligenceAvailable = afmAvailable
        self.appleIntelligenceUnavailableReason = AppleIntelligence.unavailableReason
        let lostHandoff = AppleIntelligenceLostHandoff()
        self.appleIntelligenceLost = lostHandoff
        self.cleaner = CleanupModelCatalog.makeBackend(
            selection, relay: progressRelay, onAppleIntelligenceLost: { lostHandoff.fire() })
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
        self.cleaner.setDictionary(CleanupModelCatalog.promptSnapshot(dictionary.snapshot, for: selection))
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
            paster: GuardedPaster(
                inner: self.paster,
                accessibilityGranted: { TCC.accessibilityGranted() },
                currentFrontmost: frontmostPID),
            history: self.history,
            config: pipelineConfig,
            clock: { Date().timeIntervalSince1970 },
            // keyDown runs on main (tap callback), so a direct read is safe.
            frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
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
            replacementPairs: { [dictionary] in dictionary.allPairs }
        )
        pipeline.setCleaner(self.cleaner, name: selection.storageID)

        dictionary.onChange = { [weak self] snapshot in
            // Fires on the store's queue; hop to the main actor.
            Task { @MainActor in
                self?.applyDictionaryChange(snapshot)
            }
        }

        progressRelay.set { [weak self] label, fraction in
            Task { @MainActor in
                guard let self, self.cleanupLoadInFlight else { return }
                self.cleanupModelStatus = CleanupModelCatalog.statusText(label: label, fraction: fraction)
                self.cleanupModelProgress = fraction
                if fraction < 1 { self.cleanupModelDidDownload = true }
            }
        }
        sttProgressRelay.set { [weak self] label, fraction in
            Task { @MainActor in
                self?.sttDownloadStatus = fraction < 1 ? CleanupModelCatalog.statusText(label: label, fraction: fraction) : nil
            }
        }
        appleIntelligenceLost.set { [weak self] in
            Task { @MainActor in self?.handleAppleIntelligenceLost() }
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
        startGrantWatch()
    }

    private func preloadAtStartup() {
        let engine = engines[activeEngineName]
        let cleaner = self.cleaner
        let cleanupEnabled = self.cleanupEnabled
        let logger = self.logger
        Task { [weak self] in
            let t0 = Date()
            await engine?.preload()
            // Stale-cleaner guard: a model switch during the STT preload above
            // may already have committed a new cleaner and unloaded this one.
            // Preloading the captured `cleaner` now would resurrect an orphan
            // that nothing (unloadIdleModels only unloads `self.cleaner`)
            // ever unloads. Re-check on the main actor, with no suspension
            // between the check and the call.
            if cleanupEnabled, let self, self.cleaner === cleaner {
                self.cleanupLoadInFlight = true
                await cleaner.preload()
                // A user-initiated switch may have started downloading while
                // this preload ran; it owns the flag and the status line then.
                if self.pendingCleanupModel == nil {
                    self.cleanupLoadInFlight = false
                    self.cleanupModelStatus = nil
                    self.cleanupModelProgress = nil
                }
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

    /// Grants change in System Settings, which scribe can't observe, so re-probe on a timer and on return to the app.
    /// Without this a revoked permission only shows while the Setup window is open.
    private func startGrantWatch() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshGrants()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshGrants() }
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
        if cleaner.holdsMemory, await cleaner.isLoaded {
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
        errorRevert?.cancel()
        if newState == .error {
            // Sticky for 5 s so the ⚠ glyph and status line can be seen; the next state clears it earlier.
            errorRevert = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, self.state == .error else { return }
                self.state = .idle
            }
        }
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
        refreshAppleIntelligenceAvailability()
        // Deferred: a flip can reinstall the event tap, which must not happen inside the tap's own callback.
        Task { [weak self] in self?.refreshGrants() }

        if let engine = engines[activeEngineName] {
            let cleaner = self.cleaner
            let cleanupEnabled = self.cleanupEnabled
            // LazyModel coalesces concurrent loads; an in-flight load can't be cancelled.
            Task { [weak self] in
                if await !engine.isLoaded {
                    await engine.preload()
                }
                // `self?.cleaner === cleaner`: skip if a switch replaced the
                // cleaner while we awaited (see preloadAtStartup).
                if cleanupEnabled, await !cleaner.isLoaded, self?.cleaner === cleaner {
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

    /// Same load → commit → unload shape as switchEngine. Each selection
    /// builds a FRESH backend instance (unlike the shared engines dict), so
    /// nothing else owns it and a superseded load can always be unloaded.
    /// Precondition: every later `preload()` of a captured cleaner (startup,
    /// key-down, dictionary re-warm) re-checks `self.cleaner === captured`
    /// after its await — otherwise a stale task re-loads an instance that
    /// was already unloaded and is no longer reachable.
    func switchCleanupModel(to id: CleanupModelID) {
        guard case .model = activeSelection else { return }  // custom path overrides the picker
        if id == .appleIntelligence && !AppleIntelligence.isAvailable {
            refreshAppleIntelligenceAvailability()
            return
        }
        let name = id.rawValue
        switch EngineSwitch.action(selecting: name, active: activeCleanupModel, pending: pendingCleanupModel) {
        case .ignore:
            return
        case .revert:
            cleanupSwitchTask?.cancel()
            cleanupSwitchTask = nil
            pendingCleanupModel = nil
            cleanupLoadInFlight = false
            cleanupModelStatus = nil
            cleanupModelProgress = nil
        case .begin:
            cleanupSwitchTask?.cancel()
            pendingCleanupModel = name
            let selection = CleanupModelCatalog.Selection.model(id)
            let spec = CleanupModelCatalog.spec(id)
            let handoff = appleIntelligenceLost
            let newCleaner = CleanupModelCatalog.makeBackend(
                selection, relay: progressRelay, onAppleIntelligenceLost: { handoff.fire() })
            newCleaner.setDictionary(CleanupModelCatalog.promptSnapshot(dictionary.snapshot, for: selection))
            let previous = cleaner
            let previousLabel = activeSelectionLabel
            let logger = self.logger
            cleanupLoadInFlight = true
            cleanupModelStatus = "Loading \(spec.label)…"
            cleanupModelProgress = nil
            cleanupModelDidDownload = false
            cleanupSwitchTask = Task { [weak self] in
                await newCleaner.preload()
                guard let self else { return }
                if Task.isCancelled {
                    await newCleaner.unload()
                    return
                }
                self.cleanupLoadInFlight = false
                guard await newCleaner.isLoaded else {
                    self.pendingCleanupModel = nil
                    self.cleanupModelStatus = "Couldn't load \(spec.label) — still using \(previousLabel)"
                    self.cleanupModelProgress = nil
                    logger.log("cleanup model switch to \(name) failed to load")
                    self.refreshDownloadedModels()
                    return
                }
                // Second cancellation check: `await newCleaner.isLoaded` above is a suspension point a revert or newer switch can land in (switchEngine has none between its check and commit).
                if Task.isCancelled {
                    await newCleaner.unload()
                    return
                }
                self.cleaner = newCleaner
                self.activeSelection = selection
                self.pipeline.setCleaner(newCleaner, name: name)
                self.activeCleanupModel = name
                self.pendingCleanupModel = nil
                // Persists user picks AND the AFM→Gemma runtime fallback on
                // purpose: after a fallback the stored choice follows what
                // is actually running (unlike init, which never overwrites).
                self.settings.cleanupModel = name
                self.cleanupModelStatus = nil
                self.cleanupModelProgress = nil
                logger.log("switched cleanup model to \(name)")
                if self.cleanupModelDidDownload {
                    self.cleanupModelDidDownload = false
                    self.notify("\(spec.label) is ready.")
                }
                // The switch counts as activity: without this a model that
                // just finished loading can be idle-unloaded within 60 s.
                self.idleTracker.touch(now: ProcessInfo.processInfo.systemUptime)
                await previous.unload()
                self.refreshDownloadedModels()
            }
        }
    }

    private var activeSelectionLabel: String {
        if case .model(let id) = activeSelection { return CleanupModelCatalog.spec(id).label }
        return "the custom model"
    }

    /// D1: the dictation that hit this already pasted raw (clean() threw);
    /// move off Apple Intelligence so the next one is cleaned again.
    private func handleAppleIntelligenceLost() {
        appleIntelligenceAvailable = false
        appleIntelligenceUnavailableReason = AppleIntelligence.unavailableReason
        // pending == nil: refresh runs on every key-down, so without this a
        // fallback switch already in flight would re-notify each dictation.
        // didFallback…: set once, even if the fallback load FAILS — a failed
        // load leaves AFM active and pasting raw (accepted); the flag is what
        // stops every key-down from re-notifying + retrying, so the user gets
        // exactly one notification even when the fallback fails.
        guard activeCleanupModel == CleanupModelID.appleIntelligence.rawValue,
            pendingCleanupModel == nil, !didFallbackFromAppleIntelligence
        else { return }
        didFallbackFromAppleIntelligence = true
        let target = CleanupModelCatalog.fallbackID(isDownloaded: { self.modelStatuses[$0]?.isDownloaded ?? false })
        logger.log("apple intelligence unavailable — switching cleanup to \(target.rawValue)")
        notify("Apple Intelligence is unavailable — switching cleanup to \(CleanupModelCatalog.spec(target).label)…")
        switchCleanupModel(to: target)
    }

    func refreshAppleIntelligenceAvailability() {
        let available = AppleIntelligence.isAvailable
        if available != appleIntelligenceAvailable { appleIntelligenceAvailable = available }
        appleIntelligenceUnavailableReason = AppleIntelligence.unavailableReason
        if available { didFallbackFromAppleIntelligence = false }
        if !available { handleAppleIntelligenceLost() }
    }

    /// Disk status for every downloadable model. Pure filesystem reads.
    nonisolated static func computeModelStatuses(_ store: CleanupModelStore) -> [CleanupModelID: CleanupModelStore.Status] {
        var out: [CleanupModelID: CleanupModelStore.Status] = [:]
        for spec in CleanupModelCatalog.all {
            if let repo = spec.repoID { out[spec.id] = store.status(repo) }
        }
        return out
    }

    /// Re-reads disk state off the main actor (sizing walks blobs/).
    func refreshDownloadedModels() {
        Task.detached { [weak self] in
            let statuses = AppModel.computeModelStatuses(CleanupModelStore())
            // Bind to a local `let` before the nested closure: referencing the
            // captured weak `var` inside a @Sendable closure is a Swift 6 error.
            guard let self else { return }
            await MainActor.run { self.modelStatuses = statuses }
        }
    }

    func deleteCleanupModel(_ id: CleanupModelID) {
        guard canDeleteModel(id, active: activeCleanupModel, pending: pendingCleanupModel),
            let repo = CleanupModelCatalog.spec(id).repoID
        else { return }
        let logger = self.logger
        Task.detached { [weak self] in
            do {
                try CleanupModelStore().delete(repo)
                logger.log("deleted cleanup model \(id.rawValue)")
            } catch {
                logger.log("deleting cleanup model \(id.rawValue) failed: \(error)")
            }
            await self?.refreshDownloadedModels()
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
        cleaner.setDictionary(CleanupModelCatalog.promptSnapshot(snapshot, for: activeSelection))
        logger.log(
            "dictionary updated: \(snapshot.glossary.count) learned terms, \(snapshot.pairs.count) pairs"
        )
        Task { [weak self, cleaner] in
            if await cleaner.isLoaded, self?.cleaner === cleaner {
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

    /// Re-reads all probes. A false→true flip on mic or Input Monitoring reacts without a restart.
    func refreshGrants() {
        let fresh = GrantStatus(
            microphone: TCC.microphoneGranted(),
            accessibility: TCC.accessibilityGranted(),
            inputMonitoring: TCC.inputMonitoringGranted())
        let change = GrantChange(from: grants, to: fresh)

        // Publish only on change: each write rebuilds the menu bar and closes any open submenu.
        if change.publish {
            grants = fresh
        }
        if change.microphoneNewlyGranted {
            prewarmRecorderIfGranted()
        }
        if change.inputMonitoringNewlyGranted {
            // Reinstalls the tap; on failure it flips grants.inputMonitoring back to false itself.
            activateHotkeyIfNeeded()
        }
    }

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
            OnboardingWindow(model: model)
        }

        Window("scribe dictionary", id: dictionaryWindowID) {
            DictionaryWindow(model: model)
        }

        Window("scribe models", id: modelsWindowID) {
            ModelsWindow(model: model)
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

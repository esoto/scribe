import Foundation

/// Owns the active cleanup backend and everything about changing it: the load → commit → unload switch protocol,
/// the Apple Intelligence fallback, download progress for the status line, and the on-disk model list.
/// Collaborators come in through `init` closures; nothing here knows the app's composition root.
@MainActor
final class CleanupModelController: ObservableObject {
    typealias MakeBackend = (
        CleanupModelCatalog.Selection, ProgressRelay,
        _ onAppleIntelligenceLost: @escaping @Sendable () -> Void,
        _ onLog: @escaping @Sendable (String) -> Void
    ) -> any CleanupModelBackend

    private(set) var cleaner: any CleanupModelBackend
    private(set) var activeSelection: CleanupModelCatalog.Selection
    /// Awaited by tests; nil once a revert abandons the switch.
    private(set) var cleanupSwitchTask: Task<Void, Never>?

    @Published private(set) var activeCleanupModel: String
    @Published private(set) var pendingCleanupModel: String?
    @Published private(set) var cleanupModelStatus: String?
    /// Download fraction (0…1) while a cleanup model downloads; nil otherwise.
    @Published private(set) var cleanupModelProgress: Double?
    @Published private(set) var appleIntelligenceAvailable: Bool
    @Published private(set) var appleIntelligenceUnavailableReason: String?
    @Published private(set) var modelStatuses: [CleanupModelID: CleanupModelStore.Status]

    var activeCleanupFidelitySafe: Bool { activeSelection.fidelitySafe }

    var activeSelectionLabel: String {
        if case .model(let id) = activeSelection { return CleanupModelCatalog.spec(id).label }
        return "the custom model"
    }

    private let settings: AppSettings
    private let makeBackend: MakeBackend
    private let computeStatuses: @Sendable () -> [CleanupModelID: CleanupModelStore.Status]
    private let deleteModel: @Sendable (String) throws -> Void
    private let isAppleIntelligenceAvailable: () -> Bool
    private let readAppleIntelligenceUnavailableReason: () -> String?
    private let dictionarySnapshot: () -> DictionarySnapshot
    private let onCleanerCommitted: (any CleanupModelBackend, String) -> Void
    private let notify: (String, NoticeKind) -> Void
    private let touchIdle: () -> Void
    private let failureStickySeconds: Double
    private let log: @Sendable (String) -> Void

    /// Bridges backend download progress (any thread) to this controller, which can't be captured while its
    /// stored properties are still initializing.
    private let progressRelay = ProgressRelay()
    private let appleIntelligenceLost: AppleIntelligenceLostHandoff
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
    /// Drops a failed switch's "Couldn't load…" status after `failureStickySeconds`; a newer switch cancels it.
    private var failureClear: Task<Void, Never>?

    init(
        settings: AppSettings,
        makeBackend: @escaping MakeBackend,
        computeStatuses: @escaping @Sendable () -> [CleanupModelID: CleanupModelStore.Status],
        deleteModel: @escaping @Sendable (String) throws -> Void,
        isAppleIntelligenceAvailable: @escaping () -> Bool,
        appleIntelligenceUnavailableReason: @escaping () -> String?,
        dictionarySnapshot: @escaping () -> DictionarySnapshot,
        onCleanerCommitted: @escaping (any CleanupModelBackend, String) -> Void,
        notify: @escaping (String, NoticeKind) -> Void,
        touchIdle: @escaping () -> Void,
        failureStickySeconds: Double = 10,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.settings = settings
        self.makeBackend = makeBackend
        self.computeStatuses = computeStatuses
        self.deleteModel = deleteModel
        self.isAppleIntelligenceAvailable = isAppleIntelligenceAvailable
        self.readAppleIntelligenceUnavailableReason = appleIntelligenceUnavailableReason
        self.dictionarySnapshot = dictionarySnapshot
        self.onCleanerCommitted = onCleanerCommitted
        self.notify = notify
        self.touchIdle = touchIdle
        self.failureStickySeconds = failureStickySeconds
        self.log = log

        let statuses = computeStatuses()
        let afmAvailable = isAppleIntelligenceAvailable()
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
        self.appleIntelligenceUnavailableReason = appleIntelligenceUnavailableReason()
        let lostHandoff = AppleIntelligenceLostHandoff()
        self.appleIntelligenceLost = lostHandoff
        self.cleaner = makeBackend(selection, progressRelay, { lostHandoff.fire() }, log)

        progressRelay.set { [weak self] label, fraction in
            Task { @MainActor in
                guard let self, self.cleanupLoadInFlight else { return }
                self.cleanupModelStatus = CleanupModelCatalog.statusText(label: label, fraction: fraction)
                self.cleanupModelProgress = fraction
                if fraction < 1 { self.cleanupModelDidDownload = true }
            }
        }
        lostHandoff.set { [weak self] in
            Task { @MainActor in self?.handleAppleIntelligenceLost() }
        }
    }

    // MARK: - Switching

    /// Same load → commit → unload shape as switchEngine. Each selection
    /// builds a FRESH backend instance (unlike the shared engines dict), so
    /// nothing else owns it and a superseded load can always be unloaded.
    /// Precondition: every later `preload()` of a captured cleaner (startup,
    /// key-down, dictionary re-warm) re-checks `self.cleaner === captured`
    /// after its await — otherwise a stale task re-loads an instance that
    /// was already unloaded and is no longer reachable.
    func switchCleanupModel(to id: CleanupModelID) {
        guard case .model = activeSelection else { return }  // custom path overrides the picker
        if id == .appleIntelligence && !isAppleIntelligenceAvailable() {
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
            failureClear?.cancel()
            failureClear = nil
            pendingCleanupModel = name
            let selection = CleanupModelCatalog.Selection.model(id)
            let spec = CleanupModelCatalog.spec(id)
            let handoff = appleIntelligenceLost
            let log = self.log
            let newCleaner = makeBackend(selection, progressRelay, { handoff.fire() }, log)
            newCleaner.setDictionary(CleanupModelCatalog.promptSnapshot(dictionarySnapshot(), for: selection))
            let previous = cleaner
            let previousLabel = activeSelectionLabel
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
                let loaded = await newCleaner.isLoaded
                // Second cancellation check: the `isLoaded` await is a suspension point a revert or newer switch can
                // land in. It sits before the failure branch so a stale failure can't clear the newer switch's state.
                if Task.isCancelled {
                    await newCleaner.unload()
                    return
                }
                guard loaded else {
                    self.pendingCleanupModel = nil
                    self.cleanupModelStatus = "Couldn't load \(spec.label) — still using \(previousLabel)"
                    self.cleanupModelProgress = nil
                    log("cleanup model switch to \(name) failed to load")
                    self.scheduleFailureClear()
                    self.refreshDownloadedModels()
                    return
                }
                self.cleaner = newCleaner
                self.activeSelection = selection
                self.onCleanerCommitted(newCleaner, name)
                self.activeCleanupModel = name
                self.pendingCleanupModel = nil
                // Persists user picks AND the AFM→Gemma runtime fallback on
                // purpose: after a fallback the stored choice follows what
                // is actually running (unlike init, which never overwrites).
                self.settings.cleanupModel = name
                self.cleanupModelStatus = nil
                self.cleanupModelProgress = nil
                log("switched cleanup model to \(name)")
                if self.cleanupModelDidDownload {
                    self.cleanupModelDidDownload = false
                    self.notify("\(spec.label) is ready.", .info)
                }
                // The switch counts as activity: without this a model that
                // just finished loading can be idle-unloaded within 60 s.
                self.touchIdle()
                await previous.unload()
                self.refreshDownloadedModels()
            }
        }
    }

    /// Lets the failure message be read, then drops it so a one-off failure doesn't pin the status line forever.
    private func scheduleFailureClear() {
        failureClear?.cancel()
        let seconds = failureStickySeconds
        failureClear = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.cleanupModelStatus = nil
            self.failureClear = nil
        }
    }

    // MARK: - Apple Intelligence

    /// D1: the dictation that hit this already pasted raw (clean() threw);
    /// move off Apple Intelligence so the next one is cleaned again.
    func handleAppleIntelligenceLost() {
        if appleIntelligenceAvailable { appleIntelligenceAvailable = false }
        refreshUnavailableReason()
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
        log("apple intelligence unavailable — switching cleanup to \(target.rawValue)")
        notify(
            "Apple Intelligence is unavailable — switching cleanup to \(CleanupModelCatalog.spec(target).label)…",
            .problem)
        switchCleanupModel(to: target)
    }

    /// `@Published` publishes on every assignment and this runs on every key-down; an unchanged reason must not
    /// rebuild the menu, the Models pane or the Dictionary window.
    private func refreshUnavailableReason() {
        let reason = readAppleIntelligenceUnavailableReason()
        if reason != appleIntelligenceUnavailableReason { appleIntelligenceUnavailableReason = reason }
    }

    func refreshAppleIntelligenceAvailability() {
        let available = isAppleIntelligenceAvailable()
        if available != appleIntelligenceAvailable { appleIntelligenceAvailable = available }
        refreshUnavailableReason()
        if available { didFallbackFromAppleIntelligence = false }
        if !available { handleAppleIntelligenceLost() }
    }

    // MARK: - Residency

    /// Startup preload of `cleaner`, which the caller captured before it awaited the STT preload.
    /// Returns whether the cleanup model is usable: not attempted (disabled or superseded) is not a failure.
    func preloadAtStartup(_ cleaner: any CleanupModelBackend, enabled: Bool) async -> Bool {
        var cleanupLoaded = true
        // Stale-cleaner guard: a model switch during the STT preload
        // may already have committed a new cleaner and unloaded this one.
        // Preloading the captured `cleaner` now would resurrect an orphan
        // that nothing (unloadIfResident only unloads `self.cleaner`)
        // ever unloads. Re-check on the main actor, with no suspension
        // between the check and the call.
        if enabled, self.cleaner === cleaner {
            cleanupLoadInFlight = true
            await cleaner.preload()
            // A switch that committed during the warm-up unloads this cleaner; that is superseded, not failed.
            let loaded = await cleaner.isLoaded
            cleanupLoaded = loaded || self.cleaner !== cleaner
            // A user-initiated switch may have started downloading while
            // this preload ran; it owns the flag and the status line then.
            if pendingCleanupModel == nil {
                cleanupLoadInFlight = false
                cleanupModelStatus = nil
                cleanupModelProgress = nil
            }
        }
        return cleanupLoaded
    }

    /// Key-down warm-up of `cleaner`, which the caller captured before it awaited the STT warm-up.
    func warmUpIfNeeded(_ cleaner: any CleanupModelBackend, enabled: Bool) async {
        // `self.cleaner === cleaner`: skip if a switch replaced the
        // cleaner while we awaited (see preloadAtStartup).
        if enabled, await !cleaner.isLoaded, self.cleaner === cleaner {
            await cleaner.preload()
        }
    }

    /// Idle sweep: frees the current cleaner if it holds memory and is resident. True when it unloaded.
    func unloadIfResident() async -> Bool {
        if cleaner.holdsMemory, await cleaner.isLoaded {
            await cleaner.unload()
            return true
        }
        return false
    }

    // MARK: - Disk

    /// Disk status for every downloadable model. Pure filesystem reads.
    nonisolated static func computeModelStatuses(_ store: CleanupModelStore) -> [CleanupModelID: CleanupModelStore.Status] {
        var out: [CleanupModelID: CleanupModelStore.Status] = [:]
        for spec in CleanupModelCatalog.all {
            if let repo = spec.repoID { out[spec.id] = store.status(repo) }
        }
        return out
    }

    /// Re-reads disk state off the main actor (sizing walks blobs/).
    @discardableResult
    func refreshDownloadedModels() -> Task<Void, Never> {
        let computeStatuses = self.computeStatuses
        return Task.detached { [weak self] in
            let statuses = computeStatuses()
            // Bind to a local `let` before the nested closure: referencing the
            // captured weak `var` inside a @Sendable closure is a Swift 6 error.
            guard let self else { return }
            await MainActor.run { self.modelStatuses = statuses }
        }
    }

    /// Nil when refused: the model in use (or being switched to) can't be deleted.
    @discardableResult
    func deleteCleanupModel(_ id: CleanupModelID) -> Task<Void, Never>? {
        guard canDeleteModel(id, active: activeCleanupModel, pending: pendingCleanupModel),
            let repo = CleanupModelCatalog.spec(id).repoID
        else { return nil }
        let log = self.log
        let deleteModel = self.deleteModel
        return Task.detached { [weak self] in
            do {
                try deleteModel(repo)
                log("deleted cleanup model \(id.rawValue)")
            } catch {
                log("deleting cleanup model \(id.rawValue) failed: \(error)")
            }
            await self?.refreshDownloadedModels()
        }
    }
}

import Foundation

/// Owns the STT engines and everything about changing the active one: the load → commit → unload switch
/// protocol and the status line that says a switch is loading or failed.
/// Collaborators come in through `init` closures; nothing here knows the app's composition root.
@MainActor
final class EngineController: ObservableObject {
    @Published private(set) var activeEngineName: String
    /// Target of the in-flight switch; nil when none.
    @Published private(set) var pendingEngineName: String?
    /// "Loading Whisper…" while a switch loads; after a failed one, "Couldn't load Whisper — still using Parakeet"
    /// for `failureStickySeconds`, then nil.
    @Published private(set) var engineStatus: String?

    let engines: [String: UnloadableEngine]
    /// Awaited by tests; nil once a revert abandons the switch.
    private(set) var engineSwitchTask: Task<Void, Never>?

    var activeEngine: UnloadableEngine { engines[activeEngineName]! }

    private let settings: AppSettings
    private let onEngineCommitted: (UnloadableEngine, String) -> Void
    private let failureStickySeconds: Double
    private let log: @Sendable (String) -> Void
    private var statusClear: Task<Void, Never>?

    init(
        engines: [String: UnloadableEngine],
        startingEngine: String,
        settings: AppSettings,
        onEngineCommitted: @escaping (UnloadableEngine, String) -> Void,
        failureStickySeconds: Double = 10,
        log: @escaping @Sendable (String) -> Void
    ) {
        precondition(engines[startingEngine] != nil, "starting engine must be one of the engines")
        self.engines = engines
        self.activeEngineName = startingEngine
        self.settings = settings
        self.onEngineCommitted = onEngineCommitted
        self.failureStickySeconds = failureStickySeconds
        self.log = log
    }

    /// The name the user sees in the status line, not the settings key.
    static func label(_ name: String) -> String {
        switch name {
        case "parakeet": return "Parakeet"
        case "whisper": return "Whisper"
        default: return name
        }
    }

    // MARK: - Switching

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
            setStatus(nil)
        case .begin:
            engineSwitchTask?.cancel()
            pendingEngineName = name
            setStatus("Loading \(Self.label(name))…")
            let previousEngine = engines[activeEngineName]
            engineSwitchTask = Task { [weak self] in
                await newEngine.preload()
                guard let self else { return }
                if Task.isCancelled {
                    await self.unloadIfSuperseded(newEngine, name: name)
                    return
                }
                // `LazyModel.preload` swallows load errors, so the model being resident is the only success signal.
                let loaded = await newEngine.isLoaded
                // Second cancellation check: the `isLoaded` await is a suspension point a revert or newer switch can
                // land in. It sits before the failure branch so a stale failure can't clear the newer switch's state.
                if Task.isCancelled {
                    await self.unloadIfSuperseded(newEngine, name: name)
                    return
                }
                guard loaded else {
                    self.pendingEngineName = nil
                    self.setStatus(
                        "Couldn't load \(Self.label(name)) — still using \(Self.label(self.activeEngineName))")
                    self.log("engine switch to \(name) failed to load")
                    self.scheduleStatusClear()
                    return
                }
                self.onEngineCommitted(newEngine, name)
                self.activeEngineName = name
                self.pendingEngineName = nil
                self.setStatus(nil)
                self.settings.engine = name
                self.log("switched engine to \(name)")
                await previousEngine?.unload()
            }
        }
    }

    /// Superseded mid-load: drop the load unless a newer selection landed back on this engine.
    private func unloadIfSuperseded(_ engine: UnloadableEngine, name: String) async {
        if EngineSwitch.shouldUnloadSuperseded(name, active: activeEngineName, pending: pendingEngineName) {
            await engine.unload()
        }
    }

    // MARK: - Status

    private func setStatus(_ text: String?) {
        statusClear?.cancel()
        statusClear = nil
        engineStatus = text
    }

    /// Lets the failure message be read, then drops it so a one-off failure doesn't pin the status row forever.
    private func scheduleStatusClear() {
        let seconds = failureStickySeconds
        statusClear = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.engineStatus = nil
            self.statusClear = nil
        }
    }

    // MARK: - Residency

    /// Idle sweep: frees every resident engine. True when anything was unloaded.
    func unloadAll() async -> Bool {
        var unloadedAny = false
        for engine in engines.values {
            if await engine.isLoaded {
                await engine.unload()
                unloadedAny = true
            }
        }
        return unloadedAny
    }
}

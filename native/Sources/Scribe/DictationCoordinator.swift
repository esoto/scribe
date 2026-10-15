import AppKit
import Foundation
import UserNotifications

/// Test seam over `UNUserNotificationCenter`.
protocol Notifier {
    func requestAuthorization(log: @escaping @Sendable (String) -> Void)
    func deliver(title: String, body: String, onError: @escaping @Sendable (Error) -> Void)
}

/// Live `Notifier`. Excluded from unit tests: the notification center needs a real app bundle.
struct UserNotifier: Notifier {
    func requestAuthorization(log: @escaping @Sendable (String) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log("notification authorization failed: \(error)")
            } else if !granted {
                log("notification authorization denied")
            }
        }
    }

    func deliver(title: String, body: String, onError: @escaping @Sendable (Error) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { onError(error) }
        }
    }
}

/// The slice of `HotkeyMonitor` the coordinator drives; the real one installs a `CGEventTap`.
protocol HotkeyMonitoring: AnyObject {
    var onModifierEvent: ((String) -> Void)? { get set }
    func install() throws
    func reinstall() throws
    func uninstall()
    func forgetHeldKey()
}

extension HotkeyMonitor: HotkeyMonitoring {}

/// What the coordinator needs of the recorder besides arming it (the pipeline owns that, via `RecorderLike`).
protocol RecorderPreparing: AnyObject {
    func prewarm() throws
    func setPreferredInput(uid: String?)
}

extension Recorder: RecorderPreparing {}

/// How the pipeline reports back. Handed to the pipeline factory so the coordinator owns the hop to the main actor.
struct PipelineSinks {
    let onState: (PipelineState) -> Void
    let onNotice: (String) -> Void
    let saveFailedAudio: ([Float]) -> Void
    let onHint: (String) -> Void
    let onPasted: () -> Void
}

/// Recording runtime: the pipeline, the hotkey tap, the hold watchdog, the published state with its sticky
/// error, and the sounds and notifications that go with them.
@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: PipelineState = .idle
    /// A short verdict on the last dictation ("Pasted raw — …"), cleared after `hintSeconds` or by the next key-down.
    @Published private(set) var hint: String?

    /// Key-down work that isn't about recording (idle touch, availability refresh, model warm-up).
    /// Runs first, so it is already under way when the watchdog is armed and the pipeline starts.
    var onKeyDown: () -> Void = {}

    // IUOs: both factories hand back objects whose callbacks reach `self`, which needs a fully initialized self.
    private(set) var pipeline: DictationPipeline!
    private var hotkeyMonitor: HotkeyMonitoring!
    private(set) var errorRevert: Task<Void, Never>?
    private(set) var hintClear: Task<Void, Never>?
    private(set) var holdWatchdog: Task<Void, Never>?

    private let recorder: RecorderPreparing
    private let pipelineConfig: PipelineConfig
    private(set) var hotkey: HotKey
    private let makeHotkeyMonitor: (HotKey, @escaping () -> Void, @escaping () -> Void) -> HotkeyMonitoring
    private let notifier: Notifier
    private let playSound: (String) -> Void
    private let soundsEnabled: () -> Bool
    private let microphoneGranted: () -> Bool
    private let reportInputMonitoring: (Bool) -> Void
    private let errorStickySeconds: Double
    private let hintSeconds: Double
    private let failedAudioURL: URL
    private let log: @Sendable (String) -> Void

    init(
        recorder: RecorderPreparing,
        pipelineConfig: PipelineConfig,
        hotkey: HotKey,
        makePipeline: (PipelineSinks) -> DictationPipeline,
        makeHotkeyMonitor: @escaping (_ key: HotKey, _ onDown: @escaping () -> Void, _ onUp: @escaping () -> Void)
            -> HotkeyMonitoring,
        notifier: Notifier,
        playSound: @escaping (String) -> Void,
        soundsEnabled: @escaping () -> Bool,
        microphoneGranted: @escaping () -> Bool,
        reportInputMonitoring: @escaping (Bool) -> Void,
        errorStickySeconds: Double = 5,
        hintSeconds: Double = 4,
        failedAudioURL: URL = FileLogger.logsDirectory.appendingPathComponent("last_failed.wav"),
        log: @escaping @Sendable (String) -> Void
    ) {
        self.recorder = recorder
        self.pipelineConfig = pipelineConfig
        self.hotkey = hotkey
        self.makeHotkeyMonitor = makeHotkeyMonitor
        self.notifier = notifier
        self.playSound = playSound
        self.soundsEnabled = soundsEnabled
        self.microphoneGranted = microphoneGranted
        self.reportInputMonitoring = reportInputMonitoring
        self.errorStickySeconds = errorStickySeconds
        self.hintSeconds = hintSeconds
        self.failedAudioURL = failedAudioURL
        self.log = log

        // The pipeline calls these from its own threads; each hops to the main actor.
        self.pipeline = makePipeline(
            PipelineSinks(
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
                onHint: { [weak self] message in
                    Task { @MainActor in
                        self?.showHint(message)
                    }
                },
                onPasted: { [weak self] in
                    Task { @MainActor in
                        self?.playPasteCue()
                    }
                }))
        self.hotkeyMonitor = buildHotkeyMonitor(for: hotkey)
    }

    private func buildHotkeyMonitor(for key: HotKey) -> HotkeyMonitoring {
        makeHotkeyMonitor(
            key,
            { [weak self] in self?.handleKeyDown() },
            { [weak self] in self?.handleKeyUp() })
    }

    // MARK: - Startup

    /// Prewarms the recorder, installs the hotkey tap and the sleep observer, and asks for notification
    /// permission. Must run on main (CGEventTap).
    func start() {
        // Only prewarms if already granted; the prompt comes only from the onboarding Request button.
        prewarmRecorderIfGranted()

        hotkeyMonitor.onModifierEvent = { [log] line in log("tap: \(line)") }
        do {
            try hotkeyMonitor.install()
            reportInputMonitoring(true)
            log("hotkey installed (key=\(hotkey.rawValue))")
        } catch {
            log("hotkey install failed: \(error)")
            reportInputMonitoring(false)
        }

        // Sleep mid-hold can swallow the key-up; the buffered audio must not paste into whatever has focus on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.holdWatchdog?.cancel()
                self?.pipeline.cancelHold()
                self?.hotkeyMonitor.forgetHeldKey()
            }
        }

        notifier.requestAuthorization(log: log)
    }

    /// Live-activates the hotkey tap after Input Monitoring is granted. Must run on main.
    func activateHotkeyIfNeeded() {
        do {
            try hotkeyMonitor.reinstall()
            reportInputMonitoring(true)
        } catch {
            log("hotkey reinstall failed: \(error)")
            reportInputMonitoring(false)
        }
    }

    /// Best-effort prewarm of the recorder's audio engine without starting capture. Guarded on the
    /// current grant so it never triggers the mic prompt; failure is non-fatal.
    func prewarmRecorderIfGranted() {
        guard microphoneGranted() else { return }
        do {
            try recorder.prewarm()
            log("recorder prewarmed")
        } catch {
            log("recorder prewarm failed: \(error)")
        }
    }

    // MARK: - Settings forwarded to the recorder and pipeline

    /// Switches the capture device (nil = system default). The built-in mic avoids Bluetooth HFP renegotiation delay.
    func selectMicrophone(uid: String?) {
        recorder.setPreferredInput(uid: uid)
        log("microphone set to \(uid ?? "system default")")
        prewarmRecorderIfGranted()
    }

    func setCleanupEnabled(_ on: Bool) {
        pipeline.cleanupEnabled = on
    }

    /// Swaps the hotkey at runtime. The old tap goes first, while its monitor is still retained, and a hold in
    /// progress ends: the old key's release will never arrive. The new monitor is kept even when its install
    /// fails, so the Input Monitoring retry rebuilds the tap for the new key.
    func setHotkey(_ key: HotKey) {
        holdWatchdog?.cancel()
        pipeline.cancelHold()
        hotkeyMonitor.uninstall()

        hotkey = key
        hotkeyMonitor = buildHotkeyMonitor(for: key)
        hotkeyMonitor.onModifierEvent = { [log] line in log("tap: \(line)") }
        do {
            try hotkeyMonitor.install()
            reportInputMonitoring(true)
        } catch {
            log("hotkey install failed: \(error)")
            reportInputMonitoring(false)
        }
        log("hotkey changed to \(key.rawValue)")
    }

    // MARK: - Pipeline callbacks (always entered on @MainActor — see the sinks in init)

    func applyState(_ newState: PipelineState) {
        state = newState
        errorRevert?.cancel()
        if newState == .error {
            // Sticky so the ⚠ glyph and status line can be seen; the next state clears it earlier.
            let sticky = errorStickySeconds
            errorRevert = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(sticky * 1e9))
                guard !Task.isCancelled, let self, self.state == .error else { return }
                self.state = .idle
            }
        }
        guard soundsEnabled() else { return }
        if newState == .recording {
            playSound("Pop")
        } else if newState == .error {
            playSound("Basso")
        }
    }

    func notify(_ message: String) {
        notifier.deliver(title: "scribe", body: message) { [log] error in
            log("notification delivery failed: \(message) (\(error))")
        }
    }

    func showHint(_ message: String) {
        // With the mic off every hold is silent, so "No speech heard" would just repeat itself; point at the fix.
        if message == DictationPipeline.noSpeechHint, !microphoneGranted() {
            notify("Microphone is off — open Setup / Doctor…")
            return
        }
        hint = message
        hintClear?.cancel()
        let seconds = hintSeconds
        hintClear = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.hint = nil
        }
    }

    func playPasteCue() {
        if soundsEnabled() { playSound("Tink") }
    }

    func saveFailedAudio(_ pcm: [Float]) {
        do {
            try WavWriter.write(pcm: pcm, sampleRate: UInt32(pipelineConfig.sampleRate), to: failedAudioURL)
        } catch {
            log("failed to save failed-audio wav: \(error)")
        }
    }

    // MARK: - Hotkey wiring

    /// Runs the key-down hook, arms the hold watchdog, and forwards to the pipeline. Runs on main (CGEventTap callback).
    func handleKeyDown() {
        // A new dictation supersedes the last one's verdict.
        hintClear?.cancel()
        if hint != nil { hint = nil }
        onKeyDown()

        // A release the tap never reports must not leave the mic recording until the ring buffer overflows.
        let maxHold = pipelineConfig.maxHold
        holdWatchdog?.cancel()
        holdWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maxHold * 1e9))
            guard !Task.isCancelled else { return }
            self?.pipeline.forceStop()
            self?.hotkeyMonitor.forgetHeldKey()
        }
        pipeline.keyDown()
    }

    func handleKeyUp() {
        holdWatchdog?.cancel()
        pipeline.keyUp()
    }
}

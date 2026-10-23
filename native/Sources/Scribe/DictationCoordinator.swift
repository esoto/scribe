import AppKit
import Foundation
import UserNotifications

/// Test seam over `UNUserNotificationCenter` delivery. The authorization prompt belongs to the Setup window's
/// Notifications row (`NotificationAuthorizing`), so a first run doesn't meet it unexplained.
protocol Notifier {
    func deliver(title: String, body: String, onError: @escaping @Sendable (Error) -> Void)
}

/// Live `Notifier`. Excluded from unit tests: the notification center needs a real app bundle.
struct UserNotifier: Notifier {
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

/// Good news ("Gemma 4 E4B is ready.") is delivered like any notice but is not the Doctor's last problem.
enum NoticeKind {
    case problem, info
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
    /// The latest problem notice and when it was raised, for the Doctor's "Last problem" row. Kept even when
    /// delivery fails; good news never replaces it.
    @Published private(set) var lastNotice: (text: String, at: Date)?

    /// Key-down work that isn't about recording (idle touch, availability refresh, model warm-up).
    /// Runs first, so it is already under way when the watchdog is armed and the pipeline starts.
    var onKeyDown: () -> Void = {}

    // IUOs: both factories hand back objects whose callbacks reach `self`, which needs a fully initialized self.
    private(set) var pipeline: DictationPipeline!
    private var hotkeyMonitor: HotkeyMonitoring!
    private(set) var errorRevert: Task<Void, Never>?
    private(set) var hintClear: Task<Void, Never>?
    private(set) var holdWatchdog: Task<Void, Never>?
    private(set) var hudHide: Task<Void, Never>?
    private(set) var hudShow: Task<Void, Never>?

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
    /// The guarded paste with no key-down app: only Accessibility is checked.
    private let repaste: (String) throws -> Void
    /// The menu is still closing when its action fires; ⌘V waits this long so it lands in the user's app.
    private let repasteDelay: Double
    /// The recording pill; nil in tests that don't care about it.
    private let hud: HUDModel?
    private let hudEnabled: () -> Bool
    private let hudResultSeconds: Double
    /// A hold shorter than this is a discarded tap, so the pill waits it out before showing.
    private var holdThreshold: Double
    /// Reads key-down and key-up as hold-to-talk or, in `holdOrLatch`, a double tap that latches. Main-only.
    private var taps: TapInterpreter
    /// A latched recording has no key to release, so it gets its own, longer cap.
    private let latchMaxSeconds: Double
    private let now: () -> Double

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
        repaste: @escaping (String) throws -> Void,
        repasteDelay: Double = 0.2,
        hud: HUDModel? = nil,
        hudEnabled: @escaping () -> Bool = { true },
        hudResultSeconds: Double = HUDModel.resultSeconds,
        // nil follows pipelineConfig, which is also where the pipeline's tap cutoff starts.
        holdThreshold: Double? = nil,
        hotkeyMode: HotkeyMode = .hold,
        latchMaxSeconds: Double = 240,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
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
        self.repaste = repaste
        self.repasteDelay = repasteDelay
        self.hud = hud
        self.hudEnabled = hudEnabled
        self.hudResultSeconds = hudResultSeconds
        let resolvedThreshold = holdThreshold ?? pipelineConfig.holdThreshold
        self.holdThreshold = resolvedThreshold
        // The tap filter and the pill's delay share one threshold: a press shorter than it is a tap.
        self.taps = TapInterpreter(mode: hotkeyMode, tapMax: resolvedThreshold)
        self.latchMaxSeconds = latchMaxSeconds
        self.now = now
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
                // The latch's tap may never come; on wake the first tap must start a recording, not stop a dead one.
                self?.taps.reset()
            }
        }
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

    func setEnhanceAudioEnabled(_ on: Bool) {
        pipeline.enhanceAudioEnabled = on
    }

    func setVoiceCommandsEnabled(_ on: Bool) {
        pipeline.voiceCommandsEnabled = on
    }

    /// One entry point, so the pipeline's tap cutoff, the pill's delay and the double-tap filter can't drift apart.
    func setHoldThreshold(_ seconds: Double) {
        holdThreshold = seconds
        taps.tapMax = seconds
        pipeline.setHoldThreshold(seconds)
    }

    /// A recording in progress ends first: its tap or release was read under the old mode, and the interpreter's
    /// memory of it goes with the change. The dictation so far is kept, not discarded.
    func setHotkeyMode(_ mode: HotkeyMode) {
        if pipeline.isArmed { endHold() }
        taps.mode = mode
        taps.reset()
    }

    /// `scribe://toggle`: starts a latched recording, or ends whatever is recording (a latch or a held key).
    /// `pipeline.isArmed` is the seam for "a hold is in progress": it flips synchronously with the recorder, while
    /// `state` only follows after the pipeline's hop to the main actor, so two quick toggles would misread it.
    func toggleLatched() {
        if pipeline.isArmed {
            endHold()
            taps.reset()
        } else {
            taps.latchExternally()
            beginHold(latched: true)
        }
    }

    /// Turning the pill off hides it at once; turning it on needs nothing, the next dictation shows it.
    func setHudEnabled(_ on: Bool) {
        if !on {
            hudShow?.cancel()
            hudHide?.cancel()
            hud?.hide()
        }
    }

    /// Microphone level from the recorder, hopped to the main actor by the caller.
    func reportLevel(rms: Double) {
        hud?.setLevel(rms: rms)
    }

    /// Swaps the hotkey at runtime. The old tap goes first, while its monitor is still retained, and a hold in
    /// progress ends: the old key's release will never arrive. The new monitor is kept even when its install
    /// fails, so the Input Monitoring retry rebuilds the tap for the new key.
    func setHotkey(_ key: HotKey) {
        holdWatchdog?.cancel()
        pipeline.cancelHold()
        taps.reset()
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
        hudShow?.cancel()
        if newState == .error {
            // Sticky so the ⚠ glyph and status line can be seen; the next state clears it earlier.
            let sticky = errorStickySeconds
            errorRevert = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(sticky * 1e9))
                guard !Task.isCancelled, let self, self.state == .error else { return }
                self.state = .idle
            }
        }
        if let hud, hudEnabled() {
            hudHide?.cancel()
            switch newState {
            case .recording: showListeningAfterTheTapThreshold(hud)
            case .processing: hud.show(.processing)
            case .error:
                hud.show(.problem("Error — check log"))
                scheduleHudHide(hud)
            case .idle:
                // process() emits the verdict (hint or paste cue) before this idle: leave it up briefly.
                switch hud.phase {
                case .result, .problem: scheduleHudHide(hud)
                default: hud.hide()
                }
            }
        }
        guard soundsEnabled() else { return }
        if newState == .recording {
            playSound("Pop")
        } else if newState == .error {
            playSound("Basso")
        }
    }

    /// The pipeline throws away a hold shorter than the threshold, so showing the pill at once would flash it on
    /// every accidental tap. Any later state cancels this, and a processing or error pill replaces it.
    private func showListeningAfterTheTapThreshold(_ hud: HUDModel) {
        // An imported or hand-edited threshold can be negative or not finite, and UInt64(_:) traps on both.
        let seconds = holdThreshold.isFinite ? max(holdThreshold, 0) : 0
        hudShow = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            hud.show(.listening)
        }
    }

    private func scheduleHudHide(_ hud: HUDModel) {
        let seconds = hudResultSeconds
        hudHide = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled else { return }
            hud.hide()
        }
    }

    /// Every caller but the cleanup model's "ready" message reports a problem, hence the default.
    func notify(_ message: String, kind: NoticeKind = .problem) {
        if kind == .problem { lastNotice = (message, Date()) }
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
        showVerdictOnPill(message)
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
        showVerdictOnPill("Pasted")
        if soundsEnabled() { playSound("Tink") }
    }

    /// A verdict replaces Transcribing… or an earlier verdict. Hidden means the pill is off or this is Paste Again;
    /// listening means an earlier queued job finished during the next hold and must not cover its level bars.
    private func showVerdictOnPill(_ text: String) {
        guard let hud, hudEnabled() else { return }
        switch hud.phase {
        case .processing, .result, .problem: hud.show(.result(text))
        case .hidden, .listening: break
        }
    }

    /// History → Paste Again, and `scribe://paste-last`. Guard failures read like a dictation's.
    func pasteAgain(_ text: String) {
        let delay = repasteDelay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard let self else { return }
            do {
                try self.repaste(text)
                self.playPasteCue()
            } catch let guarded as PasteGuardError {
                self.notify(guarded.notice)
            } catch {
                self.log("paste again failed: \(error)")
                self.notify("Paste failed — press ⌘V to paste manually")
            }
        }
    }

    func saveFailedAudio(_ pcm: [Float]) {
        do {
            try WavWriter.write(pcm: pcm, sampleRate: UInt32(pipelineConfig.sampleRate), to: failedAudioURL)
        } catch {
            log("failed to save failed-audio wav: \(error)")
        }
    }

    // MARK: - Hotkey wiring

    /// Runs on main (CGEventTap callback). The interpreter decides whether this press starts a hold, starts a latch
    /// (a double tap), or is the tap that ends one.
    func handleKeyDown() {
        switch taps.down(at: now()) {
        case .start: beginHold(latched: false)
        case .startLatched: beginHold(latched: true)
        case .stopLatched: endHold()
        case .stop, .ignore: break
        }
    }

    func handleKeyUp() {
        // No reset on the way out: a short release is the first half of a double tap and the interpreter remembers it.
        if taps.up(at: now()) == .stop { endHold() }
    }

    /// Runs the key-down hook, arms the hold watchdog, and forwards to the pipeline.
    private func beginHold(latched: Bool) {
        // A new dictation supersedes the last one's verdict.
        hintClear?.cancel()
        if hint != nil { hint = nil }
        onKeyDown()

        // A release the tap never reports must not leave the mic recording until the ring buffer overflows; a latch
        // nobody taps off gets the same backstop, at its own cap and with a notice that says how to start again.
        let cap = latched ? latchMaxSeconds : pipelineConfig.maxHold
        let notice = latched ? "Stopped after \(Int(latchMaxSeconds / 60)) min — tap to start again" : nil
        holdWatchdog?.cancel()
        holdWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cap * 1e9))
            guard !Task.isCancelled else { return }
            self?.pipeline.forceStop(notice: notice)
            self?.hotkeyMonitor.forgetHeldKey()
            self?.taps.reset()
        }
        pipeline.keyDown()
        guard latched else { return }
        guard pipeline.isArmed else {
            // The recorder would not start: nothing is latched, and the next tap must not be eaten as its stop.
            holdWatchdog?.cancel()
            taps.reset()
            return
        }
        showListeningAtOnce()
    }

    /// The double tap has already outlasted the tap filter, and a hands-free recording needs its pill up at once.
    /// A plain hold waits out the threshold in `applyState` instead.
    private func showListeningAtOnce() {
        guard let hud, hudEnabled() else { return }
        hudShow?.cancel()
        hudHide?.cancel()
        hud.show(.listening)
    }

    private func endHold() {
        holdWatchdog?.cancel()
        pipeline.keyUp()
    }
}

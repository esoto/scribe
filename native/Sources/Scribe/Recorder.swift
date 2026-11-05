import CoreAudio
import Foundation

struct RecorderError: Error {
    let message: String
}

/// Seam over the audio engine so `Recorder` can be tested without hardware.
protocol EngineControl: AnyObject {
    var isRunning: Bool { get }
    var onSamples: (([Float]) -> Void)? { get set }
    /// Must not light the OS microphone indicator.
    func prepare()
    func start() throws
    /// Turns off the mic indicator; prepared resources are kept for a fast restart.
    func stop()
    func setPreferredInput(uid: String?)
    /// The input the current engine is bound to; nil when it can't be read or CoreAudio doesn't know the device.
    var boundInput: BoundInput? { get }
}

/// Mic capture: an armed ring buffer fed by a pre-installed input tap.
final class Recorder: RecorderLike {
    private let buffer: RingBuffer
    private let engineControl: EngineControl
    private let lock = NSLock()
    private var armed = false
    /// RMS of each captured chunk while armed, for the recording pill's level bars. Called on the audio thread.
    var onLevel: ((Double) -> Void)?

    init(maxSeconds: Double = 300, sampleRate: Double = 16000, engineControl: EngineControl = AVEngineControl()) {
        self.buffer = RingBuffer(maxSeconds: maxSeconds, sampleRate: sampleRate)
        self.engineControl = engineControl
        engineControl.onSamples = { [weak self] chunk in self?.ingest(chunk) }
    }

    func ingest(_ chunk: [Float]) {
        lock.lock()
        let isArmed = armed
        lock.unlock()
        guard isArmed else { return }
        buffer.append(chunk)
        onLevel?(Gates.rms(chunk))
    }

    func arm() throws {
        // Clear first so a re-arm without an intervening disarm() discards
        // whatever had accumulated, same as the Python reference.
        buffer.clear()
        if !engineControl.isRunning {
            try engineControl.start()
        }
        lock.lock()
        armed = true
        lock.unlock()
    }

    func disarm() -> [Float] {
        lock.lock()
        armed = false
        lock.unlock()
        let pcm = buffer.drain()
        if engineControl.isRunning {
            engineControl.stop()
        }
        return pcm
    }

    /// Preallocates engine resources without starting capture. Never while armed: once macOS stops the engine
    /// mid-hold it reads as not running, and preparing it would rebuild the engine under the recording.
    func prewarm() throws {
        guard !engineControl.isRunning else { return }
        engineControl.prepare()
    }

    func setPreferredInput(uid: String?) {
        engineControl.setPreferredInput(uid: uid)
    }

    var boundInput: BoundInput? { engineControl.boundInput }
}

/// AVAudioEngine adapter. Before every start it re-checks that the engine still captures from the chosen microphone,
/// because macOS can move it to the system default behind scribe's back (a headset connecting, a Bluetooth profile switch).
/// The checks run against a `CaptureEngine`, so they are tested with a fake; `LiveCaptureEngine` is verified manually.
/// Callers run on the main actor and never `prepare` or `start` while armed, between key-down and key-up. That
/// discipline is what keeps a rebuild off a live recording: once macOS stops the engine mid-hold, `isRunning` is
/// false although the recording is still armed, so the running check in `InputRebind` alone would not protect it.
/// Only the notification and audio threads touch the flags behind `stateLock`.
final class AVEngineControl: EngineControl {
    var onSamples: (([Float]) -> Void)?

    private let onLog: ((String) -> Void)?
    private let resolveDevice: (String) -> AudioDeviceID?
    private let describeDevice: (AudioDeviceID) -> BoundInput?
    private let makeEngine: () -> CaptureEngine
    private var engine: CaptureEngine
    private var tapInstalled = false
    private var preferredInputUID: String?
    private var missLogged = false
    private var lastRebuildTarget: InputRebind.Target?
    private var didNotStickLogged = false

    /// Guards the flags that the notification and audio threads write and the starting thread reads.
    private let stateLock = NSLock()
    private var configurationChanged = false
    private var convertErrorLogged = false

    init(
        onLog: ((String) -> Void)? = nil,
        resolveDevice: @escaping (String) -> AudioDeviceID? = { AudioDevices.deviceID(forUID: $0) },
        describeDevice: @escaping (AudioDeviceID) -> BoundInput? = { AudioDevices.boundInput(forDeviceID: $0) },
        makeEngine: @escaping () -> CaptureEngine = { LiveCaptureEngine() }
    ) {
        self.onLog = onLog
        self.resolveDevice = resolveDevice
        self.describeDevice = describeDevice
        self.makeEngine = makeEngine
        engine = makeEngine()
        watchConfigurationChanges()
    }

    var isRunning: Bool { engine.isRunning }

    var boundInput: BoundInput? { engine.boundDevice.flatMap(describeDevice) }

    func prepare() {
        readyForCapture()
        engine.prepare()
    }

    func start() throws {
        readyForCapture()
        do {
            try engine.start()
        } catch {
            throw RecorderError(message: "could not start audio engine: \(error)")
        }
    }

    func stop() {
        // pause(), not stop(): keeps prepared resources for a fast next start.
        engine.pause()
    }

    func setPreferredInput(uid: String?) {
        preferredInputUID = uid
        // A same-UID call rebuilds too, so selecting always makes a fresh bind, and a new selection earns one more
        // attempt after a bind that did not stick.
        lastRebuildTarget = nil
        rebuildEngine()
    }

    /// Binds a fresh engine, or checks that a bound one still captures from the chosen device and rebuilds it if not.
    private func readyForCapture() {
        // Looked up once: the id that is compared is the id that gets bound.
        let resolved = preferredInputUID.flatMap(resolveDevice)
        // A fresh engine is bound by its first tap install; comparing it first would only rebuild it again.
        guard tapInstalled else {
            installTap(resolved: resolved, announcingRebind: false)
            return
        }
        let bound = engine.boundDevice
        // The binding held, so a later mismatch is a new problem and earns a rebuild.
        if let resolved, bound == resolved { lastRebuildTarget = nil }
        let action = InputRebind.decide(
            wantedUID: preferredInputUID,
            resolved: resolved,
            bound: bound,
            configurationChanged: stateLock.withLock { configurationChanged },
            lastRebuildTarget: lastRebuildTarget,
            running: engine.isRunning)
        switch action {
        case .keep, .deferWhileRunning:
            break
        case .useSystemDefault(let uid):
            // This engine is already bound and nothing rebuilds it here, so it stays on its binding.
            logMissOnce(uid, outcome: "keeping the current engine")
        case .bindingDidNotStick(let uid):
            logDidNotStickOnce(uid)
        case .rebuild:
            rebuildEngine()
            lastRebuildTarget = rebuildTarget(resolved: resolved)
            installTap(resolved: resolved, announcingRebind: true)
        }
    }

    private func rebuildTarget(resolved: AudioDeviceID?) -> InputRebind.Target? {
        guard let uid = preferredInputUID, let resolved else { return nil }
        return InputRebind.Target(uid: uid, device: resolved)
    }

    /// AVAudioEngine can't swap the input device under a live tap, so any rebind is a new engine.
    private func rebuildEngine() {
        engine.stop()
        engine = makeEngine()
        tapInstalled = false
        missLogged = false
        didNotStickLogged = false
        stateLock.withLock { convertErrorLogged = false }
        watchConfigurationChanges()
    }

    private func installTap(resolved: AudioDeviceID?, announcingRebind: Bool) {
        tapInstalled = true
        // Must run before the tap reads the input format, which is the device's native format.
        bindPreferredInput(resolved: resolved, announcingRebind: announcingRebind)
        // The bind can make the engine post a configuration change of its own. The tap installed next already reads
        // the format that change produced, so keeping the flag would rebuild a second time on the next start.
        stateLock.withLock { configurationChanged = false }
        engine.installTap(
            onSamples: { [weak self] chunk in self?.onSamples?(chunk) },
            onConvertError: { [weak self] description in self?.reportConvertError(description) })
    }

    /// Falls back to the system default if the preferred device is unplugged.
    private func bindPreferredInput(resolved: AudioDeviceID?, announcingRebind: Bool) {
        guard let uid = preferredInputUID else { return }
        guard let device = resolved else {
            logMissOnce(uid, outcome: "using system default")
            return
        }
        let status = engine.bind(device: device)
        if status != noErr {
            // Fall back to the system default rather than a dead engine.
            onLog?("recorder: could not select input device \(uid): OSStatus \(status)")
        } else if announcingRebind {
            onLog?("recorder: input rebound to \(uid)")
        }
    }

    /// `outcome` says what the engine does instead, which differs for a new engine and one that is already bound.
    private func logMissOnce(_ uid: String, outcome: String) {
        guard !missLogged else { return }
        missLogged = true
        onLog?("recorder: input \(uid) not found; \(outcome)")
    }

    private func logDidNotStickOnce(_ uid: String) {
        guard !didNotStickLogged else { return }
        didNotStickLogged = true
        onLog?("recorder: input \(uid) did not stick; keeping the current engine")
    }

    private func watchConfigurationChanges() {
        engine.observeConfigurationChange { [weak self] in self?.configurationDidChange() }
    }

    /// Only flags the engine: it has stopped itself, and the next start rebuilds it, never a live recording.
    private func configurationDidChange() {
        stateLock.withLock { configurationChanged = true }
        onLog?("recorder: audio configuration changed")
    }

    /// Every failing chunk is dropped, so only the first per engine is worth a line.
    private func reportConvertError(_ description: String) {
        let isFirst = stateLock.withLock { () -> Bool in
            let first = !convertErrorLogged
            convertErrorLogged = true
            return first
        }
        if isFirst { onLog?("recorder: audio conversion failed: \(description)") }
    }
}

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

    /// Preallocates engine resources without starting capture.
    func prewarm() throws {
        guard !engineControl.isRunning else { return }
        engineControl.prepare()
    }

    func setPreferredInput(uid: String?) {
        engineControl.setPreferredInput(uid: uid)
    }
}

/// AVAudioEngine adapter. Before every start it re-checks that the engine still captures from the chosen microphone,
/// because macOS can move it to the system default behind scribe's back (a headset connecting, a Bluetooth profile switch).
/// The checks run against a `CaptureEngine`, so they are tested with a fake; `LiveCaptureEngine` is verified manually.
final class AVEngineControl: EngineControl {
    var onSamples: (([Float]) -> Void)?

    private let onLog: ((String) -> Void)?
    private let resolveDevice: (String) -> AudioDeviceID?
    private let makeEngine: () -> CaptureEngine
    private var engine: CaptureEngine
    private var tapInstalled = false
    private var preferredInputUID: String?
    private var missLogged = false

    /// Guards the flags that the notification and audio threads write and the starting thread reads.
    private let stateLock = NSLock()
    private var configurationChanged = false
    private var convertErrorLogged = false

    init(
        onLog: ((String) -> Void)? = nil,
        resolveDevice: @escaping (String) -> AudioDeviceID? = { AudioDevices.deviceID(forUID: $0) },
        makeEngine: @escaping () -> CaptureEngine = { LiveCaptureEngine() }
    ) {
        self.onLog = onLog
        self.resolveDevice = resolveDevice
        self.makeEngine = makeEngine
        engine = makeEngine()
        watchConfigurationChanges()
    }

    var isRunning: Bool { engine.isRunning }

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
        // Re-picking the same device rebuilds too: the engine may have drifted off it, and this is the manual way back.
        rebuildEngine()
    }

    /// Binds a fresh engine, or checks that a bound one still captures from the chosen device and rebuilds it if not.
    private func readyForCapture() {
        // A fresh engine is bound by its first tap install; comparing it first would only rebuild it again.
        guard tapInstalled else {
            installTap(announcingRebind: false)
            return
        }
        let action = InputRebind.decide(
            wantedUID: preferredInputUID,
            resolved: preferredInputUID.flatMap(resolveDevice),
            bound: engine.boundDevice,
            configurationChanged: stateLock.withLock { configurationChanged },
            running: engine.isRunning)
        switch action {
        case .keep, .deferWhileRunning:
            break
        case .useSystemDefault(let uid):
            logMissOnce(uid)
        case .rebuild:
            rebuildEngine()
            installTap(announcingRebind: true)
        }
    }

    /// AVAudioEngine can't swap the input device under a live tap, so any rebind is a new engine.
    private func rebuildEngine() {
        engine.stop()
        engine = makeEngine()
        tapInstalled = false
        missLogged = false
        stateLock.withLock {
            configurationChanged = false
            convertErrorLogged = false
        }
        watchConfigurationChanges()
    }

    private func installTap(announcingRebind: Bool) {
        tapInstalled = true
        // Must run before the tap reads the input format, which is the device's native format.
        bindPreferredInput(announcingRebind: announcingRebind)
        engine.installTap(
            onSamples: { [weak self] chunk in self?.onSamples?(chunk) },
            onConvertError: { [weak self] description in self?.reportConvertError(description) })
    }

    /// Falls back to the system default if the preferred device is unplugged.
    private func bindPreferredInput(announcingRebind: Bool) {
        guard let uid = preferredInputUID else { return }
        guard let device = resolveDevice(uid) else {
            logMissOnce(uid)
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

    private func logMissOnce(_ uid: String) {
        guard !missLogged else { return }
        missLogged = true
        onLog?("recorder: input \(uid) not found; using system default")
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

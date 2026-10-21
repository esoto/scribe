import AudioToolbox
import AVFoundation
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

/// AVAudioEngine adapter. Converts the tap to 16 kHz mono via `AVAudioConverter`, since the input node can't be forced to 16 kHz.
/// Needs a real mic and TCC permission, so it is untested and verified manually.
final class AVEngineControl: EngineControl {
    var onSamples: (([Float]) -> Void)?

    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private var preferredInputUID: String?
    private let onLog: ((String) -> Void)?

    init(onLog: ((String) -> Void)? = nil) {
        self.onLog = onLog
    }

    var isRunning: Bool { engine.isRunning }

    func prepare() {
        installTapIfNeeded()
        engine.prepare()
    }

    func start() throws {
        installTapIfNeeded()
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
        guard uid != preferredInputUID else { return }
        preferredInputUID = uid
        // Must rebuild: AVAudioEngine can't swap the input device under a live tap.
        engine.stop()
        engine = AVAudioEngine()
        tapInstalled = false
    }

    /// Falls back to the system default if the preferred device is unplugged.
    private func applyPreferredInput() {
        guard let uid = preferredInputUID,
            let devID = AudioDevices.deviceID(forUID: uid),
            let audioUnit = engine.inputNode.audioUnit
        else { return }
        var dev = devID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            // Fall back to the system default rather than a dead engine.
            onLog?("recorder: could not select input device \(uid): OSStatus \(status)")
        }
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        tapInstalled = true

        // Must run before reading the input format, which is the device's native format.
        applyPreferredInput()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] pcmBuffer, _ in
            self?.convertAndForward(pcmBuffer, converter: converter, targetFormat: targetFormat)
        }
    }

    private func convertAndForward(
        _ pcmBuffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        guard conversionError == nil, let channelData = outBuffer.floatChannelData else { return }
        let frameLength = Int(outBuffer.frameLength)
        onSamples?(Array(UnsafeBufferPointer(start: channelData[0], count: frameLength)))
    }
}

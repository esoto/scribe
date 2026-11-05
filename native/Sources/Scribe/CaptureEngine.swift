import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// The slice of `AVAudioEngine` that `AVEngineControl` drives, so the rebind logic runs in tests without hardware.
protocol CaptureEngine: AnyObject {
    var isRunning: Bool { get }
    /// The device the input unit is bound to right now; nil when it can't be read.
    var boundDevice: AudioDeviceID? { get }
    /// Binds the input unit to `device`; `noErr` on success.
    func bind(device: AudioDeviceID) -> OSStatus
    /// Installs the tap that forwards 16 kHz mono samples. It reads the device's native format, so bind first.
    /// `onConvertError` carries the description of every failed conversion, on the audio thread.
    func installTap(onSamples: @escaping ([Float]) -> Void, onConvertError: @escaping (String) -> Void)
    /// Calls `handler`, on any thread, when this engine's configuration changes. The engine has stopped itself by then.
    func observeConfigurationChange(_ handler: @escaping () -> Void)
    func prepare()
    func start() throws
    func pause()
    func stop()
}

/// `AVAudioEngine` behind `CaptureEngine`. Converts the tap to 16 kHz mono via `AVAudioConverter`, since the input
/// node can't be forced to 16 kHz. Needs a real mic and TCC permission, so it is untested and verified manually.
final class LiveCaptureEngine: CaptureEngine {
    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    var isRunning: Bool { engine.isRunning }

    var boundDevice: AudioDeviceID? {
        guard let audioUnit = engine.inputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr ? device : nil
    }

    func bind(device: AudioDeviceID) -> OSStatus {
        guard let audioUnit = engine.inputNode.audioUnit else { return kAudioUnitErr_Uninitialized }
        var device = device
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    func installTap(onSamples: @escaping ([Float]) -> Void, onConvertError: @escaping (String) -> Void) {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            onConvertError("no converter from \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { pcmBuffer, _ in
            do {
                if let chunk = try LiveCaptureEngine.convert(pcmBuffer, using: converter, to: targetFormat) {
                    onSamples(chunk)
                }
            } catch {
                onConvertError(error.localizedDescription)
            }
        }
    }

    func observeConfigurationChange(_ handler: @escaping () -> Void) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in handler() }
    }

    func prepare() { engine.prepare() }

    func start() throws { try engine.start() }

    func pause() { engine.pause() }

    func stop() { engine.stop() }

    /// Nil when the chunk is dropped without an error; throws when the converter fails.
    private static func convert(
        _ pcmBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to targetFormat: AVAudioFormat
    ) throws -> [Float]? {
        let ratio = targetFormat.sampleRate / pcmBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

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

        if let conversionError { throw conversionError }
        guard let channelData = outBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))
    }
}

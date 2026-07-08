import AVFoundation
import Foundation

struct RecorderError: Error {
    let message: String
}

/// Testable seam over the audio engine lifecycle. The real implementation
/// (`AVEngineControl`) wraps `AVAudioEngine`; tests inject a fake so the
/// armed ring-buffer logic in `Recorder` can be verified without audio
/// hardware — mirrors the `stream_factory` injection in the Python
/// reference (`scribe.recorder.Recorder`).
protocol EngineControl: AnyObject {
    var isRunning: Bool { get }
    /// Called by the adapter for every converted sample chunk it produces.
    /// `Recorder` wires this to `ingest(_:)` right after construction.
    var onSamples: (([Float]) -> Void)? { get set }
    func start() throws
}

/// Mic capture: an armed ring buffer fed by a pre-installed input tap.
///
/// Ported from `scribe.recorder.Recorder` (src/scribe/recorder.py). The
/// Python version pre-opens a `sounddevice` stream and injects a
/// `stream_factory` for testability; this port pre-opens an `AVAudioEngine`
/// tap instead and injects an `EngineControl` seam for the same reason.
/// `ingest(_:)` is the pure capture core the tests drive directly; the
/// `AVEngineControl` tap/converter plumbing that feeds it in production is
/// untestable without real hardware (see its doc comment).
final class Recorder: RecorderLike {
    private let buffer: RingBuffer
    private let engineControl: EngineControl
    private let lock = NSLock()
    private var armed = false

    init(maxSeconds: Double = 300, sampleRate: Double = 16000, engineControl: EngineControl = AVEngineControl()) {
        self.buffer = RingBuffer(maxSeconds: maxSeconds, sampleRate: sampleRate)
        self.engineControl = engineControl
        engineControl.onSamples = { [weak self] chunk in self?.ingest(chunk) }
    }

    // MARK: - Capture core (testable, no hardware)

    /// Appends a chunk to the ring buffer only while armed. In production
    /// this is fed by the AVAudioEngine tap via `engineControl.onSamples`;
    /// tests call it directly to verify armed-capture semantics.
    func ingest(_ chunk: [Float]) {
        lock.lock()
        let isArmed = armed
        lock.unlock()
        guard isArmed else { return }
        buffer.append(chunk)
    }

    func arm() throws {
        // Clear first so a re-arm without an intervening disarm() discards
        // whatever had accumulated, same as the Python reference.
        buffer.clear()
        lock.lock()
        armed = true
        lock.unlock()
        if !engineControl.isRunning {
            try engineControl.start()
        }
    }

    func disarm() -> [Float] {
        lock.lock()
        armed = false
        lock.unlock()
        return buffer.drain()
    }
}

/// Real AVAudioEngine adapter: installs an input tap at the node's native
/// format, converts to 16 kHz mono Float32 via `AVAudioConverter` (the
/// input node cannot be forced to 16 kHz directly), and forwards converted
/// samples through `onSamples`.
///
/// Excluded from unit test coverage — exercising it needs a real
/// microphone and TCC permission, neither available in `xcodebuild test`.
/// Verify manually via the app.
final class AVEngineControl: EngineControl {
    var onSamples: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        installTapIfNeeded()
        do {
            try engine.start()
        } catch {
            throw RecorderError(message: "could not start audio engine: \(error)")
        }
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        tapInstalled = true

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

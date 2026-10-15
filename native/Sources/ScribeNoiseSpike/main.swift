import AVFoundation
import FluidAudio
import Foundation

// Throwaway spike: does LocalVQE denoising help or hurt Parakeet Ultra?
// Runs each clip three ways (clean / noisy / noisy+denoised) and scores WER
// against the clean transcript. Not part of the product build.

let fixtures = "/Users/esoto/development/scribe/tests_models/fixtures"
let noiseDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/noise-spike"

func loadPcm(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let fmt = file.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return try AudioConverter().resampleBuffer(buf)
}

func words(_ s: String) -> [String] {
    s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
}

func wer(ref: String, hyp: String) -> Double {
    let r = words(ref), h = words(hyp)
    guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
    guard !h.isEmpty else { return 1 }  // empty hypothesis = total loss
    var prev = Array(0...h.count)
    for i in 1...r.count {
        var cur = [i] + Array(repeating: 0, count: h.count)
        for j in 1...h.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return Double(prev[h.count]) / Double(r.count)
}

Task {
    do {
        let models = try await AsrModels.downloadAndLoad(version: .ultra)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let vqe = try await LocalVqeManager()

        for clip in ["en", "es", "mixed"] {
            let clean = try loadPcm("\(fixtures)/\(clip).wav")
            var s0 = try TdtDecoderState()
            let ref = try await asr.transcribe(clean, decoderState: &s0)

            for snr in ["10", "5", "0", "-5"] {
                let noisy = try loadPcm("\(noiseDir)/noisy_\(clip)_\(snr)db.wav")
                var s1 = try TdtDecoderState()
                let nz = try await asr.transcribe(noisy, decoderState: &s1)

                let t0 = Date()
                let enhanced = try await vqe.process(mic: noisy)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                var s2 = try TdtDecoderState()
                let den = try await asr.transcribe(enhanced, decoderState: &s2)

                let wNoisy = wer(ref: ref.text, hyp: nz.text)
                let wDen = wer(ref: ref.text, hyp: den.text)
                let verdict = wDen < wNoisy ? "HELPS" : (wDen > wNoisy ? "HURTS" : "same")
                print(
                    "  \(clip) @ \(snr)dB SNR  noisy=\(String(format: "%.3f", wNoisy))  denoised=\(String(format: "%.3f", wDen))  -> \(verdict)  [\(ms) ms]"
                )
                if wNoisy > 0 || wDen > 0 {
                    print("      noisy   : \(nz.text)")
                    print("      denoised: \(den.text)")
                }
            }
        }
        exit(0)
    } catch {
        print("SPIKE FAILED: \(error)")
        exit(1)
    }
}

// Top-level `Task` alone does not keep the process alive.
dispatchMain()

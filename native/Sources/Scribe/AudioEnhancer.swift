import FluidAudio
import Foundation

/// Optional speech enhancement applied to captured audio before STT.
protocol AudioEnhancer {
    func enhance(_ pcm: [Float]) async throws -> [Float]
}

/// LocalVQE (acoustic echo cancellation + noise suppression + dereverberation), already
/// bundled with FluidAudio — no extra dependency, ~18 MB model on first use.
///
/// EXPERIMENTAL, and OFF by default. On synthetic pink noise it raised Parakeet's WER on
/// 8 of 12 clip/SNR combinations, including turning Spanish speech into English gibberish
/// at 0 dB SNR. Parakeet is trained on noise-injected audio and handles additive noise on
/// its own; enhancement hands it artifacts it never saw. Enable only to try it against
/// real-world noise, where LocalVQE's training data is a better match.
actor LocalVQEEnhancer: AudioEnhancer {
    private var manager: LocalVqeManager?

    func enhance(_ pcm: [Float]) async throws -> [Float] {
        let vqe: LocalVqeManager
        if let manager {
            vqe = manager
        } else {
            // Downloads and compiles on first dictation; a failure here is swallowed by the caller.
            let created = try await LocalVqeManager()
            manager = created
            vqe = created
        }
        // No far-end reference: LocalVQE still denoises and dereverberates, passing silence for it.
        return try await vqe.process(mic: pcm)
    }
}

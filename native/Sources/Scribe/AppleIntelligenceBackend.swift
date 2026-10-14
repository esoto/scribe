import Foundation
import FoundationModels

/// Apple Intelligence availability, callable on any macOS the app supports
/// (deployment target 15.0; FoundationModels is macOS 26+).
enum AppleIntelligence {
    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    /// Why it can't be used, for the Models window; nil when available.
    static var unavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "Requires macOS 26 or later" }
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else { return nil }
        switch reason {
        case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings"
        case .modelNotReady: return "Apple Intelligence is still downloading"
        @unknown default: return "Apple Intelligence is unavailable"
        }
    }
}

/// What Apple Intelligence is primed with. Starts identical to Gemma's
/// prompt; Task 11 may tune it independently, since AFM fails different
/// golden cases than Gemma.
enum AFMCleanupPrompt {
    static func instructions(with snapshot: DictionarySnapshot) -> String {
        CleanupPrompt.systemPrompt(with: snapshot)
    }

    static let fewShots: [(String, String)] = CleanupPrompt.fewShots
}

/// Cleanup via Apple's on-device model. Nothing is resident in our process,
/// so unload is a no-op and "loaded" means "available". A fresh session per
/// call: sessions accumulate turns, and `Transcript` is a value type, so
/// each call starts from the same few-shot priming.
@available(macOS 26.0, *)
final class AppleIntelligenceBackend: CleanupModelBackend, @unchecked Sendable {
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private let lock = NSLock()
    private var snapshot = DictionarySnapshot.empty
    /// Fired when a clean() finds the model gone (Apple Intelligence turned
    /// off, assets evicted) — AppModel then switches to a Gemma fallback.
    private let onUnavailable: (@Sendable () -> Void)?

    init(onUnavailable: (@Sendable () -> Void)? = nil) {
        self.onUnavailable = onUnavailable
    }

    func setDictionary(_ snapshot: DictionarySnapshot) {
        lock.withLock { self.snapshot = snapshot }
    }

    static func transcript(instructions: String) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(
                Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: instructions))],
                    toolDefinitions: []))
        ]
        for (input, output) in AFMCleanupPrompt.fewShots {
            entries.append(
                .prompt(
                    Transcript.Prompt(
                        segments: [.text(Transcript.TextSegment(content: CleanupPrompt.wrap(input)))])))
            entries.append(
                .response(
                    Transcript.Response(
                        assetIDs: [], segments: [.text(Transcript.TextSegment(content: output))])))
        }
        return Transcript(entries: entries)
    }

    static func options(for text: String) -> GenerationOptions {
        GenerationOptions(
            samplingMode: .greedy, temperature: 0,
            maximumResponseTokens: CleanupPrompt.maxTokens(inputTokens: text.count / 4))
    }

    private func currentTranscript() -> Transcript {
        Self.transcript(instructions: AFMCleanupPrompt.instructions(with: lock.withLock { snapshot }))
    }

    func clean(_ text: String) async throws -> String {
        guard model.isAvailable else {
            onUnavailable?()
            throw CleanupError(message: "Apple Intelligence unavailable: \(model.availability)")
        }
        let session = LanguageModelSession(model: model, transcript: currentTranscript())
        do {
            return try await session.respond(to: CleanupPrompt.wrap(text), options: Self.options(for: text)).content
        } catch {
            throw CleanupError(message: "\(error)")
        }
    }

    func preload() async {
        guard model.isAvailable else { return }
        LanguageModelSession(model: model, transcript: currentTranscript()).prewarm()
    }

    func unload() async {}

    var isLoaded: Bool { get async { model.isAvailable } }

    /// `isLoaded` means "usable" here (the switch commit relies on it), so it
    /// can't double as "holds memory". AppModel's idle unload keys off this
    /// instead and skips us, rather than logging a false "unloaded models".
    var holdsMemory: Bool { false }
}

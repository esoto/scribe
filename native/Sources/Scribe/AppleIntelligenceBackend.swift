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
    /// off, assets evicted) — CleanupModelController then switches to a Gemma fallback.
    private let onUnavailable: (@Sendable () -> Void)?

    init(onUnavailable: (@Sendable () -> Void)? = nil) {
        self.onUnavailable = onUnavailable
    }

    func setDictionary(_ snapshot: DictionarySnapshot) {
        lock.withLock { self.snapshot = snapshot }
    }

    static func transcript(instructions: String) -> Transcript {
        transcript(
            instructions: instructions,
            fewShots: AFMCleanupPrompt.fewShots.map { (CleanupPrompt.wrap($0.0), $0.1) })
    }

    /// `fewShots` are (prompt, response) pairs whose prompt is already wrapped the way the real query will be.
    static func transcript(instructions: String, fewShots: [(String, String)]) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(
                Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: instructions))],
                    toolDefinitions: []))
        ]
        for (prompt, response) in fewShots {
            entries.append(
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            entries.append(
                .response(
                    Transcript.Response(
                        assetIDs: [], segments: [.text(Transcript.TextSegment(content: response))])))
        }
        return Transcript(entries: entries)
    }

    static func options(for text: String) -> GenerationOptions {
        GenerationOptions(
            samplingMode: .greedy, temperature: 0,
            maximumResponseTokens: CleanupPrompt.maxTokens(inputTokens: text.count / 4))
    }

    /// `maxTokens` comes from the caller, which knows the verb (`EditPrompt.maxTokens(verb:inputTokens:)`).
    static func options(forEdit maxTokens: Int) -> GenerationOptions {
        GenerationOptions(samplingMode: .greedy, temperature: 0, maximumResponseTokens: maxTokens)
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

    /// The same few-shot priming on every call, like `clean`. The edit prompt has no vocabulary section, so a
    /// dictionary change does not touch it.
    func edit(instruction: String, text: String, maxTokens: Int) async throws -> String {
        guard model.isAvailable else {
            onUnavailable?()
            throw CleanupError(message: "Apple Intelligence unavailable: \(model.availability)")
        }
        let session = LanguageModelSession(
            model: model,
            transcript: Self.transcript(instructions: EditPrompt.systemPrompt, fewShots: EditPrompt.fewShots))
        do {
            return try await session.respond(
                to: EditPrompt.wrap(instruction: instruction, text: text),
                options: Self.options(forEdit: maxTokens)
            ).content
        } catch {
            // The error type only: a framework error can carry the prompt, and the prompt holds the selection.
            throw CleanupError(message: "Apple Intelligence edit failed: \(type(of: error))")
        }
    }

    func preload() async {
        guard model.isAvailable else { return }
        LanguageModelSession(model: model, transcript: currentTranscript()).prewarm()
    }

    func unload() async {}

    var isLoaded: Bool { get async { model.isAvailable } }

    /// `isLoaded` means "usable" here (the switch commit relies on it), so it
    /// can't double as "holds memory". CleanupModelController's idle unload keys off this
    /// instead and skips us, rather than logging a false "unloaded models".
    var holdsMemory: Bool { false }
}

import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

struct CleanupError: Error {
    let message: String
}

protocol UnloadableCleaner: CleanupBackend {
    func unload() async
    func preload() async
    var isLoaded: Bool { get async }
}

/// A cleanup backend the app can swap at runtime: lifecycle hooks plus the
/// dictionary push every model needs (callers gate what's in it — see
/// `CleanupModelCatalog.promptSnapshot`).
protocol CleanupModelBackend: UnloadableCleaner, AnyObject {
    func setDictionary(_ snapshot: DictionarySnapshot)
    /// Applies `instruction` to `text` with the edit prompt, which never shares a warm prefix with cleanup.
    /// `maxTokens` comes from the caller, which knows the verb (`EditPrompt.maxTokens(verb:inputTokens:)`).
    func edit(instruction: String, text: String, maxTokens: Int) async throws -> String
    /// False for a backend with nothing resident in our process (Apple
    /// Intelligence): idle-unload skips it. A requirement so the default is
    /// dispatched dynamically through `any CleanupModelBackend`.
    var holdsMemory: Bool { get }
}

extension CleanupModelBackend {
    var holdsMemory: Bool { true }
}

/// Warm KV cache for the fixed prompt prefix. Always `.copy()` it, never mutate: generation mutates a cache.
private struct WarmPrefix {
    var cache: [KVCache]
    var prefixLen: Int
    var prefixTokens: [Int]
    /// Extra leading tokens to strip in the FAST tier; nil means SAFE only.
    var fastPathWrapOverlap: Int?
}

/// Spec-driven MLX cleanup backend (Gemma 3 4B QAT by default; any `.mlx` CleanupModelSpec).
///
/// Caches the KV state of the fixed system+few-shot prefix and reuses a copy per call. The SAFE tier
/// renders the full chat and feeds only the suffix; the FAST tier renders only the incremental turn
/// after a startup parity gate. Both verify tokens per call and fall back to uncached generation.
///
/// The edit prompt keeps a second prefix of its own (`WarmSlots`): it warms on first use, takes the SAFE tier only,
/// and `preload()` still warms cleanup alone, so a dictation after launch pays nothing new.
///
/// `@unchecked Sendable`: warmSlots is only touched inside container.perform, which serializes calls with a
/// real async mutex; dictionarySnapshot has its own NSLock.
final class GemmaBackend: CleanupModelBackend, @unchecked Sendable {
    private let lazyModel: LazyModel<ModelContainer>
    private let onLog: (@Sendable (String) -> Void)?

    /// A slot is empty until its warm-up succeeds; a failed warm-up is not retried per call, a changed prompt retries.
    private var warmSlots = WarmSlots<WarmPrefix>()

    /// Own lock so setDictionary works from any thread without forcing a model load.
    private let dictionaryLock = NSLock()
    private var dictionarySnapshot = DictionarySnapshot.empty

    /// Applies on the next clean()/preload(); in-flight calls keep their captured prompt.
    func setDictionary(_ snapshot: DictionarySnapshot) {
        dictionaryLock.lock()
        dictionarySnapshot = snapshot
        dictionaryLock.unlock()
    }

    private func currentSystemPrompt() -> String {
        dictionaryLock.lock()
        let snapshot = dictionarySnapshot
        dictionaryLock.unlock()
        return CleanupPrompt.systemPrompt(with: snapshot)
    }

    private static let warmupSampleEN =
        "so um this is just a warm up phrase for the cache no big deal"
    private static let warmupSampleES =
        "este esto es solo una frase de calentamiento para el cache sin problema"

    /// `spec` picks the stock model; `customModelPath` overrides it with a local MLX folder.
    /// `onProgress` gets download progress (0…1) on any thread. A load from a local snapshot reports
    /// nothing; CleanupModelController clears the status line when the load ends.
    init(
        spec: CleanupModelSpec = CleanupModelCatalog.gemma3,
        customModelPath: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onLog: (@Sendable (String) -> Void)? = nil
    ) {
        self.onLog = onLog
        let configuration = GemmaBackend.localFirstConfiguration(spec: spec, customPath: customModelPath)
        lazyModel = LazyModel(label: "cleanup-\(spec.id.rawValue)", onLog: onLog) {
            // Expanded macro so the hub client uses the app-managed model store.
            try await loadModelContainer(
                from: #hubDownloader(
                    HubClient(
                        cache: HubCache(location: .fixed(directory: ModelStore.gemmaDirectory)))),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in onProgress?(progress.fractionCompleted) })
        }
    }

    /// Built directly because #huggingFaceLoadModelContainer never consults the model registries,
    /// so a bare ModelConfiguration would miss extraEOSTokens. Without <end_of_turn> as a stop token,
    /// Gemma runs to maxTokens. A custom path omits it: it is Gemma's turn token and would corrupt other families.
    /// Gemma 4 uses <turn|> instead (registry gemma4_e4b_it_4bit).
    static func modelConfiguration(
        spec: CleanupModelSpec = CleanupModelCatalog.gemma3, customPath: String? = nil
    ) -> ModelConfiguration {
        if let customPath {
            return ModelConfiguration(directory: URL(fileURLWithPath: customPath))
        }
        guard case .mlx(let repoID, let revision, let extraEOSTokens) = spec.kind else {
            preconditionFailure("GemmaBackend loads MLX models only, got \(spec.id)")
        }
        return ModelConfiguration(id: repoID, revision: revision, extraEOSTokens: extraEOSTokens)
    }

    /// Loading by id lets the hub client list the repo on huggingface.co whenever it has no tree
    /// metadata of its own (every install from before pinning), even with all files on disk. A
    /// complete pinned snapshot is handed over as a plain directory instead, so the load never
    /// touches the network. Anything less complete falls back to the pinned id, which downloads
    /// into the same cache.
    static func localFirstConfiguration(
        spec: CleanupModelSpec = CleanupModelCatalog.gemma3, customPath: String? = nil,
        store: CleanupModelStore = CleanupModelStore()
    ) -> ModelConfiguration {
        let pinned = modelConfiguration(spec: spec, customPath: customPath)
        guard customPath == nil, case .mlx(let repoID, let revision, let extraEOSTokens) = spec.kind,
            let snapshot = store.snapshotDirectory(repoID: repoID, revision: revision)
        else { return pinned }
        return ModelConfiguration(directory: snapshot, extraEOSTokens: extraEOSTokens)
    }

    /// Message list sent to Gemma. Few-shot user turns must go through wrap() like the real query,
    /// or the "never translate" instruction weakens.
    static func buildChat(for text: String, systemPrompt: String) -> [Chat.Message] {
        var messages: [Chat.Message] = [.system(systemPrompt)]
        for (input, output) in CleanupPrompt.fewShots {
            messages.append(.user(CleanupPrompt.wrap(input)))
            messages.append(.assistant(output))
        }
        messages.append(.user(CleanupPrompt.wrap(text)))
        return messages
    }

    /// The edit chat. `EditPrompt.fewShots` inputs are already wrapped, so they go in as they are.
    static func buildEditChat(
        instruction: String, text: String, systemPrompt: String = EditPrompt.systemPrompt
    ) -> [Chat.Message] {
        var messages: [Chat.Message] = [.system(systemPrompt)]
        for (wrappedInput, output) in EditPrompt.fewShots {
            messages.append(.user(wrappedInput))
            messages.append(.assistant(output))
        }
        messages.append(.user(EditPrompt.wrap(instruction: instruction, text: text)))
        return messages
    }

    /// The two queries whose common leading tokens are the edit prefix. Their instructions open with different words
    /// on purpose: the shared run then ends right after `<instruction>`, so the prefix fits every verb. Two
    /// "Rewrite it …" instructions would pin it to those words and miss for translate, fix grammar and list.
    static let editWarmupSamples: [(instruction: String, text: String)] = [
        (EditVerb.fixGrammar.instruction, warmupSampleEN),
        (EditVerb.toEnglish.instruction, warmupSampleES),
    ]

    func clean(_ text: String) async throws -> String {
        do {
            let container = try await lazyModel.get()

            let parameters = GenerateParameters(
                maxTokens: CleanupPrompt.maxTokens(inputTokens: text.count / 4),
                temperature: 0.0
            )

            // All MLX work, including the warm cache, must run inside container.perform (MLX is thread-bound).
            // chat is built inside the closure because Chat.Message isn't Sendable.
            let cleaned = try await container.perform { context in
                // Captured once so a mid-call setDictionary can't split the prompt.
                let systemPrompt = self.currentSystemPrompt()
                await self.warmUpIfNeeded(
                    context: context, parameters: parameters, slot: .cleanup, systemPrompt: systemPrompt)
                let chat = GemmaBackend.buildChat(for: text, systemPrompt: systemPrompt)
                return try await self.generateCleaned(
                    text: text, chat: chat, slot: .cleanup, parameters: parameters, context: context)
            }
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as CleanupError {
            throw error
        } catch {
            throw CleanupError(message: "\(error)")
        }
    }

    /// Mirrors `clean` with the edit prompt and the caller's token budget. Always the SAFE tier: the FAST tier's
    /// parity gate is built on the cleanup wrap. Nothing of `text` or `instruction` is logged or put in an error.
    func edit(instruction: String, text: String, maxTokens: Int) async throws -> String {
        do {
            let container: ModelContainer
            do {
                container = try await lazyModel.get()
            } catch {
                // `LazyModel` logs a failed load from `preload()` only, and an edit may be the first caller. A load
                // error holds no selection text, so its type is safe to record.
                onLog?("edit: model load failed: \(type(of: error))")
                throw error
            }
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)
            let edited = try await container.perform { context in
                await self.warmUpIfNeeded(
                    context: context, parameters: parameters, slot: .edit, systemPrompt: EditPrompt.systemPrompt)
                let chat = GemmaBackend.buildEditChat(instruction: instruction, text: text)
                return try await self.generateCleaned(
                    text: text, chat: chat, slot: .edit, parameters: parameters, context: context)
            }
            return edited.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as CleanupError {
            throw error
        } catch {
            throw GemmaBackend.editFailure(error)
        }
    }

    /// The error type only, as the Apple Intelligence edit reports it: a tokenizer or template error can quote its
    /// input, and the input holds the user's selection.
    static func editFailure(_ error: Error) -> CleanupError {
        CleanupError(message: "edit failed: \(type(of: error))")
    }

    /// The EN and ES warm-up chats of a slot, whose common leading tokens are its fixed prefix.
    private static func warmupChats(
        slot: WarmSlot, systemPrompt: String
    ) -> (en: [Chat.Message], es: [Chat.Message]) {
        switch slot {
        case .cleanup:
            return (
                buildChat(for: warmupSampleEN, systemPrompt: systemPrompt),
                buildChat(for: warmupSampleES, systemPrompt: systemPrompt)
            )
        case .edit:
            let (en, es) = (editWarmupSamples[0], editWarmupSamples[1])
            return (
                buildEditChat(instruction: en.instruction, text: en.text, systemPrompt: systemPrompt),
                buildEditChat(instruction: es.instruction, text: es.text, systemPrompt: systemPrompt)
            )
        }
    }

    /// Builds the warm prefix of `slot` for `systemPrompt`; no-op if current or already attempted.
    /// Failure is non-fatal and falls back to uncached generation. Call inside container.perform.
    private func warmUpIfNeeded(
        context: ModelContext, parameters: GenerateParameters, slot: WarmSlot, systemPrompt: String
    ) async {
        guard warmSlots.beginWarmUp(slot, systemPrompt: systemPrompt) else { return }
        let label = slot.label

        do {
            // The common leading tokens of two different queries are the fixed prefix; avoids
            // addGenerationPrompt: false, which the tokenizer bridge doesn't expose.
            // This text-only processor yields 1-D token arrays (no batch dim).
            let chats = GemmaBackend.warmupChats(slot: slot, systemPrompt: systemPrompt)
            let renderedEN = try await context.processor.prepare(input: UserInput(chat: chats.en))
            let renderedES = try await context.processor.prepare(input: UserInput(chat: chats.es))

            let tokensEN = renderedEN.text.tokens.asArray(Int.self)
            let tokensES = renderedES.text.tokens.asArray(Int.self)
            let prefixLen = GemmaBackend.commonPrefixLength(tokensEN, tokensES)

            guard prefixLen > 0, prefixLen < tokensEN.count, prefixLen < tokensES.count else {
                onLog?("\(label): prefix-reuse disabled, degenerate common prefix (\(prefixLen) tokens)")
                return
            }

            // Constructing a TokenIterator prefills `cache` in place; the iterator is discarded.
            let cache = makePromptCache(model: context.model, parameters: parameters)
            let prefixInput = LMInput(text: renderedEN.text[0..<prefixLen])
            _ = try TokenIterator(
                input: prefixInput, model: context.model, cache: cache, parameters: parameters)

            let prefixTokens = Array(tokensEN[0..<prefixLen])

            // The parity gate is built on the cleanup wrap; an edit has no FAST tier and stays SAFE.
            var fastPathWrapOverlap: Int?
            if slot == .cleanup {
                fastPathWrapOverlap = await GemmaBackend.parityGateOverlap(
                    prefixTokens: prefixTokens,
                    samples: [
                        (GemmaBackend.warmupSampleEN, tokensEN),
                        (GemmaBackend.warmupSampleES, tokensES),
                    ],
                    context: context,
                    onLog: onLog)
            }

            warmSlots.store(
                WarmPrefix(
                    cache: cache, prefixLen: prefixLen, prefixTokens: prefixTokens,
                    fastPathWrapOverlap: fastPathWrapOverlap),
                in: slot, systemPrompt: systemPrompt)
            onLog?(
                "\(label): warm prefix ready, prefixLen=\(prefixLen) fastPath=\(fastPathWrapOverlap != nil) wrapOverlap=\(fastPathWrapOverlap.map(String.init) ?? "n/a")"
            )
        } catch {
            onLog?("\(label): prefix warm-up failed, falling back to uncached generation: \(error)")
        }
    }

    /// Verifies prefixTokens + strip(incremental render) == full render for one strip amount all samples agree on.
    /// Any disagreement or mismatch disables the FAST tier.
    private static func parityGateOverlap(
        prefixTokens: [Int],
        samples: [(text: String, fullTokens: [Int])],
        context: ModelContext,
        onLog: (@Sendable (String) -> Void)?
    ) async -> Int? {
        let bos = prefixTokens.first
        var agreedOverlap: Int?

        for (sample, fullTokens) in samples {
            do {
                let incremental = try await context.processor.prepare(
                    input: UserInput(chat: [.user(CleanupPrompt.wrap(sample))]))
                var incrementalTokens = incremental.text.tokens.asArray(Int.self)
                if let bos, incrementalTokens.first == bos {
                    incrementalTokens.removeFirst()
                }

                let overlap = GemmaBackend.overlapLength(
                    suffixOf: prefixTokens, prefixOf: incrementalTokens)
                if let agreedOverlap, agreedOverlap != overlap {
                    onLog?(
                        "cleanup: prefix-reuse fast path disabled, wrap-overlap disagreement between samples (\(agreedOverlap) vs \(overlap))"
                    )
                    return nil
                }
                agreedOverlap = overlap

                let candidate = prefixTokens + Array(incrementalTokens.dropFirst(overlap))
                guard candidate == fullTokens else {
                    // Counts only: a full token dump is hundreds of ints per line.
                    onLog?(
                        "cleanup: prefix-reuse fast path disabled, token parity mismatch (expected \(fullTokens.count) tokens, got \(candidate.count))"
                    )
                    return nil
                }
            } catch {
                onLog?("cleanup: prefix-reuse fast path disabled, parity check failed: \(error)")
                return nil
            }
        }
        return agreedOverlap ?? 0
    }

    /// Longest run where the end of `a` equals the start of `b`.
    private static func overlapLength(suffixOf a: [Int], prefixOf b: [Int]) -> Int {
        var k = min(a.count, b.count)
        while k > 0 {
            if Array(a.suffix(k)) == Array(b.prefix(k)) {
                return k
            }
            k -= 1
        }
        return 0
    }

    /// Generates text for either prompt family, reusing the slot's warm prefix cache when available.
    /// FAST renders only the incremental turn (cleanup only); SAFE renders the full chat. Any token mismatch falls back
    /// to fresh generation.
    private func generateCleaned(
        text: String, chat: [Chat.Message], slot: WarmSlot, parameters: GenerateParameters, context: ModelContext
    ) async throws -> String {
        let label = slot.label
        guard let warm = warmSlots.prefix(in: slot) else {
            return try await GemmaBackend.runFreshGeneration(
                chat: chat, parameters: parameters, context: context)
        }

        let inputText: LMInput.Text
        let cache: [KVCache]

        if slot == .cleanup, let wrapOverlap = warm.fastPathWrapOverlap {
            let incremental = try await context.processor.prepare(
                input: UserInput(chat: [.user(CleanupPrompt.wrap(text))]))
            var tokens = incremental.text.tokens.asArray(Int.self)
            if let bos = warm.prefixTokens.first, tokens.first == bos {
                tokens.removeFirst()
            }
            if wrapOverlap > 0 {
                // BPE may not be concatenative at the prefix/content join (leading digit, ¿, emoji),
                // so re-verify the strip per call; a mismatch falls back to the full render.
                let toStrip = Array(tokens.prefix(wrapOverlap))
                guard tokens.count >= wrapOverlap,
                    toStrip == Array(warm.prefixTokens.suffix(wrapOverlap))
                else {
                    onLog?("\(label): fast-path boundary mismatch, using full render")
                    return try await GemmaBackend.runFreshGeneration(
                        chat: chat, parameters: parameters, context: context)
                }
                tokens.removeFirst(wrapOverlap)
            }
            guard !tokens.isEmpty else {
                return try await GemmaBackend.runFreshGeneration(
                    chat: chat, parameters: parameters, context: context)
            }
            inputText = .init(tokens: MLXArray(tokens))
            cache = warm.cache.map { $0.copy() }
        } else {
            let full = try await context.processor.prepare(input: UserInput(chat: chat))
            let fullTokens = full.text.tokens.asArray(Int.self)

            guard fullTokens.count > warm.prefixLen,
                Array(fullTokens[0..<warm.prefixLen]) == warm.prefixTokens
            else {
                onLog?("\(label): prefix mismatch for this call, falling back to uncached generation")
                return try await GemmaBackend.runFreshGeneration(
                    chat: chat, parameters: parameters, context: context)
            }

            inputText = full.text[warm.prefixLen...]
            cache = warm.cache.map { $0.copy() }
        }

        let stream = try generate(
            input: LMInput(text: inputText), cache: cache, parameters: parameters, context: context)
        var output = ""
        for await generation in stream {
            // Honor the pipeline's cancel-on-timeout, or a timed-out cleanup holds the model mutex.
            try Task.checkCancellation()
            if case .chunk(let piece) = generation {
                output += piece
            }
        }
        return output
    }

    /// Generation with no cache reuse; used when the warm cache is unavailable or a safety check fails.
    private static func runFreshGeneration(
        chat: [Chat.Message], parameters: GenerateParameters, context: ModelContext
    ) async throws -> String {
        let input = try await context.processor.prepare(input: UserInput(chat: chat))
        let stream = try generate(input: input, parameters: parameters, context: context)
        var output = ""
        for await generation in stream {
            try Task.checkCancellation()
            if case .chunk(let piece) = generation {
                output += piece
            }
        }
        return output
    }

    /// Common leading-token run; finds the prefix boundary without addGenerationPrompt: false.
    private static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] {
            n += 1
        }
        return n
    }

    /// Must drop the warm KV caches, the container, and MLX's buffer cache, or ~2.5 GB stays resident.
    /// Caches are cleared inside container.perform so it can't race clean() or edit().
    func unload() async {
        if await lazyModel.isLoaded, let container = try? await lazyModel.get() {
            await container.perform { _ in
                self.warmSlots.removeAll()
            }
        }
        await lazyModel.unload()
        Memory.clearCache()
    }
    /// Loads and warms up, so the first dictation after an idle unload doesn't pay warm-up cost.
    func preload() async {
        guard let container = await lazyModel.loadForPreload() else { return }
        let parameters = GenerateParameters(temperature: 0.0)
        await container.perform { context in
            // Current prompt, so preload also rebuilds a prefix made stale by a dictionary change.
            await self.warmUpIfNeeded(
                context: context, parameters: parameters, slot: .cleanup,
                systemPrompt: self.currentSystemPrompt())
        }
    }

    /// The cleanup prefix; the edit one is `isEditWarm`, built on the first edit.
    var isWarm: Bool { warmSlots.prefix(in: .cleanup) != nil }

    var isEditWarm: Bool { warmSlots.prefix(in: .edit) != nil }

    /// The cleanup slot's prompt, so a dictionary change stays observable.
    var warmSystemPromptForTesting: String? { warmSlots.systemPrompt(in: .cleanup) }

    /// The system prompts that have a warm prefix, sorted.
    var warmPrefixSlotsForTesting: [String] { warmSlots.systemPrompts }

    var isLoaded: Bool { get async { await lazyModel.isLoaded } }
}

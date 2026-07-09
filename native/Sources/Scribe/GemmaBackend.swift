import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Error thrown by `CleanupBackend.clean` on failure — matches the pattern
/// of `SttError` in Pipeline.swift.
struct CleanupError: Error {
    let message: String
}

/// Adds the idle-unload lifecycle hooks the app's memory manager (Task 13)
/// needs on top of `CleanupBackend.clean`.
protocol UnloadableCleaner: CleanupBackend {
    func unload() async
    func preload() async
    var isLoaded: Bool { get async }
}

/// Warm KV-cache state for the fixed prompt prefix (system prompt + 3
/// few-shot pairs) that's IDENTICAL on every `clean()` call. Built once,
/// lazily, on the first call; reused (via `.copy()`, NEVER mutated in
/// place — generation mutates a cache as it runs) on every subsequent
/// call. See `GemmaBackend.warmUpIfNeeded` / `generateCleaned` and
/// native/SPIKE-RESULTS.md "## Cleanup speed — prefix cache".
private struct WarmPrefix {
    /// One prefilled `KVCacheSimple` per transformer layer, holding the
    /// fixed prefix's KV state at offset == `prefixLen`.
    var cache: [KVCache]
    /// Token count of the fixed prefix — constant across all `clean()`
    /// calls since the prefix text never changes.
    var prefixLen: Int
    /// The literal token ids the fixed prefix (system + 3 few-shot pairs)
    /// renders to. Used both as the per-call SAFE-tier safety check
    /// (`fullTokens[0..<prefixLen] == prefixTokens`) and, via its first
    /// element, as the `<bos>` id to strip from FAST's incremental render.
    var prefixTokens: [Int]
    /// Non-nil only if the FAST tier's one-time parity gate passed
    /// (agreeing exactly across every warm-up sample) — the number of
    /// EXTRA leading tokens (beyond the re-emitted `<bos>`) to strip from
    /// every FAST-tier incremental render. Non-zero because the two-dummy
    /// `prefixLen` boundary can land a few tokens past the few-shot
    /// region, inside the shared `<start_of_turn>user\n<transcript>\n`
    /// open-wrap text that an isolated single-turn render also
    /// reconstructs from scratch (see `parityGateOverlap`'s doc comment).
    /// `nil` means every call permanently uses SAFE for the lifetime of
    /// this `GemmaBackend` instance.
    var fastPathWrapOverlap: Int?
}

/// MLX Gemma 3 4B QAT cleanup backend via `#huggingFaceLoadModelContainer`.
///
/// The system prompt + 3 few-shot pairs are IDENTICAL on every `clean()`
/// call — only the final wrapped user turn changes. Re-rendering (Jinja
/// chat template) and re-prefilling that ~290-token fixed prefix on every
/// call was measured to cost ~2.1-2.4s of the ~2.87s total wall time
/// (native/SPIKE-RESULTS.md, "Cleanup speed — prefix cache"). This backend
/// instead builds a warm KV-cache for that fixed prefix once (lazily, on
/// the first `clean()` call) and reuses a `.copy()` of it on every
/// subsequent call:
///
/// - **SAFE tier** (always available once warmed): still renders the full
///   conversation each call (so it does NOT save the ~1.5s template
///   render) but skips re-prefilling the ~0.6s prefix — feeding the model
///   only the literal suffix of that render, which is parity-exact by
///   construction. A per-call check confirms this specific render's
///   prefix tokens still match the warm cache's before trusting it; on
///   any mismatch it falls back to a fresh, uncached generation for just
///   that call.
/// - **FAST tier** (opportunistic): additionally skips the full
///   8-message-conversation render by rendering only the incremental
///   turn (~0.4s vs ~1.5s). The wrap-overlap amount is derived once from
///   an empirical, one-time startup parity gate (EN + ES samples) proving
///   `prefixTokens + incrementalTokens == fullRenderTokens` exactly for
///   those samples — but is re-verified on THIS call's actual tokens every
///   time before being trusted (see `generateCleaned`), since BPE
///   tokenization at the prefix/content boundary isn't guaranteed
///   concatenative for every possible input. Any per-call mismatch falls
///   back to a fresh, uncached generation for just that call (never a
///   silently wrong prompt); a startup gate disagreement between the EN/ES
///   samples permanently falls back to SAFE for the rest of the process.
///
/// `@unchecked Sendable`: `warmPrefix`/`warmupAttempted` are plain mutable
/// stored properties, not actor-isolated. That's safe because every read
/// or write of them happens exclusively from inside a `container.perform`
/// closure (see `clean(_:)`), and `ModelContainer` serializes ALL
/// `perform` calls through a real async mutex (`SerialAccessContainer`)
/// that holds the lock for the full duration of the async body — so two
/// `clean()` calls can never interleave their access to this state, even
/// though nothing here is compiler-checked `Sendable`. Mirrors
/// `FileLogger`/`SerialWorker`'s use of the same pattern elsewhere in this
/// target.
///
/// Confirmed from the vendored source
/// (`MLXLMCommon/Utilities/SerialAccessContainer.swift`):
/// `SerialAccessContainer.read`/`.update` funnel through a private
/// `AsyncMutex` — an `actor` that hand-rolls `isLocked` + a
/// `CheckedContinuation` waiter queue, NOT bare actor-reentrancy — whose
/// own doc comment states it exists specifically because "an `actor` does
/// not guarantee exclusive access for the duration of an `async`
/// function." So this is a real serial lock held for the whole
/// `container.perform` body, not a reentrant actor that could interleave
/// two `clean()` calls at an internal `await`.
final class GemmaBackend: UnloadableCleaner, @unchecked Sendable {
    private let lazyModel: LazyModel<ModelContainer>

    /// Set once warm-up succeeds. `nil` means either warm-up hasn't run
    /// yet or it failed — both cases fall back to `runFreshGeneration`.
    private var warmPrefix: WarmPrefix?
    /// Guards against retrying warm-up on every call after a failure.
    private var warmupAttempted = false

    /// Internal-only warm-up probe text (EN) used to compute `prefixLen`
    /// and gate the FAST tier. Never shown to users; wrapped the same way
    /// a real transcript would be via `buildChat(for:)`.
    private static let warmupSampleEN =
        "so um this is just a warm up phrase for the cache no big deal"
    /// Internal-only warm-up probe text (ES) — see `warmupSampleEN`.
    private static let warmupSampleES =
        "este esto es solo una frase de calentamiento para el cache sin problema"

    init() {
        lazyModel = LazyModel(label: "gemma-cleanup") {
            try await #huggingFaceLoadModelContainer(
                configuration: GemmaBackend.modelConfiguration()
            )
        }
    }

    /// The `ModelConfiguration` used to load the cleanup model. Constructed
    /// directly (not looked up via `LLMModelFactory`/`VLMModelFactory`'s
    /// static registry) because `#huggingFaceLoadModelContainer` takes a
    /// `ModelConfiguration` literal and never consults those registries —
    /// `resolve(configuration:from:useLatest:progressHandler:)` in
    /// MLXLMCommon/ModelFactory.swift uses the literal as-is. A bare
    /// `ModelConfiguration(id:)` therefore does NOT pick up
    /// `VLMRegistry.gemma3_4B_qat_4bit`'s `extraEOSTokens: ["<end_of_turn>"]`.
    ///
    /// Without `extraEOSTokens` set here, `ChatSession`'s stop-token set
    /// (`buildStopTokenIds` in MLXLMCommon/Evaluate.swift) only contains the
    /// tokenizer's single `eos_token` (`<eos>`, id 1, from
    /// tokenizer_config.json) — NOT `<end_of_turn>` (id 106), which is the
    /// token Gemma's chat template (and `generation_config.json`'s
    /// multi-value `eos_token_id: [1, 106]`) actually uses to end a chat
    /// turn. Confirmed via a temporary instrumented `TokenIterator` run
    /// (see the cleanup-perf investigation, native/SPIKE-RESULTS.md): the
    /// model correctly produced the cleaned sentence and then emitted
    /// `<end_of_turn>` — but since that token wasn't a registered stop, it
    /// was appended as ordinary output and generation continued, repeating
    /// `<end_of_turn>` until hitting the 200-token ceiling (`stopReason:
    /// .length`) instead of stopping after ~10 tokens like the validated
    /// Python oracle (`stopReason: .stop`).
    static func modelConfiguration() -> ModelConfiguration {
        ModelConfiguration(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            extraEOSTokens: ["<end_of_turn>"]
        )
    }

    /// Builds the exact message sequence sent to Gemma for a cleanup
    /// request: the system prompt, then each `CleanupPrompt.fewShots` pair
    /// mapped to `[.user(wrapped input), .assistant(output)]`, then the
    /// final wrapped query — `1 + 2 * fewShots.count + 1` messages in
    /// total. Pure and independent of MLX/ChatSession so it's directly
    /// testable — see GemmaChatStructureTests.swift.
    ///
    /// The few-shot user turns MUST go through `CleanupPrompt.wrap()`, same
    /// as the real query — Python's build_messages() (src/scribe/cleanup/base.py)
    /// wraps every few-shot AND real user turn in <transcript> tags. Leaving
    /// the few-shots unwrapped rendered a prompt where only the final query
    /// carried the <transcript> markup the examples never demonstrated,
    /// which measurably weakened the "never translate" instruction (2/10
    /// golden cases regressed, both English inputs translated to Spanish;
    /// fixed in Task 15 — this function, and its regression test, exist to
    /// keep that from recurring silently).
    static func buildChat(for text: String) -> [Chat.Message] {
        var messages: [Chat.Message] = [.system(CleanupPrompt.systemPrompt)]
        for (input, output) in CleanupPrompt.fewShots {
            messages.append(.user(CleanupPrompt.wrap(input)))
            messages.append(.assistant(output))
        }
        messages.append(.user(CleanupPrompt.wrap(text)))
        return messages
    }

    /// Cleans a raw dictation transcript using the Gemma 3 4B model with
    /// few-shot examples. Wraps errors into `CleanupError`.
    func clean(_ text: String) async throws -> String {
        do {
            let container = try await lazyModel.get()

            // buildChat(for:) returns [system, few-shot user/assistant
            // pairs..., final user query] — the exact message list the
            // SAFE tier's full-conversation render (and the uncached
            // fallback) sends.
            let parameters = GenerateParameters(
                maxTokens: CleanupPrompt.maxTokens(inputTokens: text.count / 4),
                temperature: 0.0
            )

            // All MLX work — including reading/mutating the warm prefix
            // cache — must run inside `container.perform`: MLX is
            // thread-bound, and `ModelContainer` serializes every call
            // through a real async mutex. See the class doc comment for
            // why that also makes `warmPrefix`/`warmupAttempted` safe as
            // plain stored properties.
            //
            // `chat` ([Chat.Message]) is built INSIDE the closure (from the
            // Sendable `text: String` captured below) rather than passed in
            // from outside — `Chat.Message` isn't `Sendable`, and building
            // it is a cheap pure-Swift operation, so there's no reason to
            // fight the `@Sendable` closure capture checker over it.
            let cleaned = try await container.perform { context in
                await self.warmUpIfNeeded(context: context, parameters: parameters)
                let chat = GemmaBackend.buildChat(for: text)
                return try await self.generateCleaned(
                    text: text, chat: chat, parameters: parameters, context: context)
            }
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as CleanupError {
            throw error
        } catch {
            throw CleanupError(message: "\(error)")
        }
    }

    /// Builds and prefills the warm prefix cache exactly once per process
    /// (idempotent: a no-op once `warmPrefix` is set, or once a prior
    /// attempt has failed). Must be called from inside `container.perform`
    /// — see `clean(_:)`.
    ///
    /// Failure here (e.g. an unexpected tokenizer error) is non-fatal: it
    /// just means every `clean()` call for the rest of this instance's
    /// lifetime falls back to the original, uncached full-conversation
    /// generation (`runFreshGeneration`) — slower, but exactly as correct
    /// as before this change.
    private func warmUpIfNeeded(context: ModelContext, parameters: GenerateParameters) async {
        guard warmPrefix == nil, !warmupAttempted else { return }
        warmupAttempted = true

        do {
            // Two different sample queries (EN + ES) rendered through the
            // same full-conversation path `clean()` uses. Their common
            // leading-token prefix is exactly the fixed system+few-shot
            // region — rendering two DIFFERENT queries sidesteps needing
            // `addGenerationPrompt: false`, which the `MLXLMCommon.Tokenizer`
            // bridge doesn't expose (all its convenience overloads hardcode
            // `addGenerationPrompt: true`).
            //
            // NOTE: this model resolves through `LLMModelFactory`'s
            // text-only `LLMUserInputProcessor` (this is a *_text* Gemma3
            // config, not the VLM one), which renders `LMInput(tokens:
            // MLXArray(promptTokens))` — a 1-D token array with NO batch
            // dimension and NO mask (confirmed empirically: `.shape` prints
            // `[N]`, not `[1, N]`). All indexing below uses a single axis
            // accordingly.
            let renderedEN = try await context.processor.prepare(
                input: UserInput(chat: GemmaBackend.buildChat(for: GemmaBackend.warmupSampleEN)))
            let renderedES = try await context.processor.prepare(
                input: UserInput(chat: GemmaBackend.buildChat(for: GemmaBackend.warmupSampleES)))

            let tokensEN = renderedEN.text.tokens.asArray(Int.self)
            let tokensES = renderedES.text.tokens.asArray(Int.self)
            let prefixLen = GemmaBackend.commonPrefixLength(tokensEN, tokensES)

            guard prefixLen > 0, prefixLen < tokensEN.count, prefixLen < tokensES.count else {
                print("[GemmaBackend] prefix-reuse disabled: degenerate common prefix (\(prefixLen))")
                return
            }

            // Prefill: construct (but never iterate) a `TokenIterator` over
            // just the prefix tokens. Its `init` calls `model.prepare(...)`,
            // which mutates the passed-in `KVCache` objects IN PLACE — so
            // once this returns, `cache` (same object references) holds the
            // prefix's KV state at offset == prefixLen. The iterator itself
            // is discarded; nothing about it needs to survive past this
            // call (see recon: prefill-without-generating primitive).
            let cache = makePromptCache(model: context.model, parameters: parameters)
            let prefixInput = LMInput(text: renderedEN.text[0..<prefixLen])
            _ = try TokenIterator(
                input: prefixInput, model: context.model, cache: cache, parameters: parameters)

            let prefixTokens = Array(tokensEN[0..<prefixLen])

            let fastPathWrapOverlap = await GemmaBackend.parityGateOverlap(
                prefixTokens: prefixTokens,
                samples: [
                    (GemmaBackend.warmupSampleEN, tokensEN),
                    (GemmaBackend.warmupSampleES, tokensES),
                ],
                context: context)

            warmPrefix = WarmPrefix(
                cache: cache, prefixLen: prefixLen, prefixTokens: prefixTokens,
                fastPathWrapOverlap: fastPathWrapOverlap)
            print(
                "[GemmaBackend] warm prefix ready: prefixLen=\(prefixLen) fastPath=\(fastPathWrapOverlap != nil) wrapOverlap=\(fastPathWrapOverlap.map(String.init) ?? "n/a")"
            )
        } catch {
            print(
                "[GemmaBackend] prefix warm-up failed, falling back to uncached generation: \(error)"
            )
        }
    }

    /// Empirically verifies, for every `(sample, fullTokens)` pair, that
    /// `prefixTokens + strip(incrementalRender(sample)) == fullTokens` for
    /// a SINGLE, sample-INDEPENDENT strip amount (exact token-id
    /// equality).
    ///
    /// The strip has two parts: the leading `<bos>` an isolated
    /// single-turn render re-emits (always dropped first, unconditionally
    /// safe since `<bos>` is a reserved special-token id that never
    /// appears as ordinary content), plus a further, empirically-measured
    /// "wrap overlap" — the two-dummy `prefixLen` boundary can land a few
    /// tokens past the few-shot region, inside the shared
    /// `<start_of_turn>user\n<transcript>\n` open-wrap text that an
    /// isolated single-turn render also reconstructs from scratch, so that
    /// wrap would otherwise appear twice.
    ///
    /// The wrap-overlap amount is measured per sample and REQUIRED to be
    /// IDENTICAL across every sample (EN and ES, maximally different
    /// content) before being trusted — this is the same rigor as the
    /// `prefixLen` boundary itself: content-independent because it's
    /// re-derived from, and must agree across, multiple diverse probes,
    /// not assumed from one. FAST is only ever enabled if every sample
    /// both agrees on the overlap AND reproduces `fullTokens` exactly with
    /// it applied; any disagreement or mismatch permanently falls back to
    /// SAFE for the rest of this instance's lifetime.
    private static func parityGateOverlap(
        prefixTokens: [Int],
        samples: [(text: String, fullTokens: [Int])],
        context: ModelContext
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
                    print(
                        "[GemmaBackend] prefix-reuse fast path disabled: wrap-overlap disagreement between samples (\(agreedOverlap) vs \(overlap))"
                    )
                    return nil
                }
                agreedOverlap = overlap

                let candidate = prefixTokens + Array(incrementalTokens.dropFirst(overlap))
                guard candidate == fullTokens else {
                    print("[GemmaBackend] prefix-reuse fast path disabled: token parity mismatch")
                    print("[GemmaBackend]   sample: \(sample)")
                    print("[GemmaBackend]   expected tokens: \(fullTokens)")
                    print("[GemmaBackend]   got tokens:      \(candidate)")
                    return nil
                }
            } catch {
                print("[GemmaBackend] prefix-reuse fast path disabled: parity check failed: \(error)")
                return nil
            }
        }
        return agreedOverlap ?? 0
    }

    /// Length of the longest run where the END of `a` equals the START of
    /// `b` — used to find how much of an isolated incremental render
    /// redundantly duplicates the tail of the warm prefix. Both inputs are
    /// small (prefix ~250-300 tokens, incremental render's fixed-wrap
    /// region a handful of tokens), so the naive O(n·k) scan is negligible
    /// — this runs at most twice per process (warm-up only).
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

    /// Generates the cleaned text for `text`, reusing the warm prefix
    /// cache when one is available.
    ///
    /// - FAST tier (only when `warm.fastPathWrapOverlap != nil`): renders
    ///   ONLY the incremental user turn (a 1-message template render,
    ///   ~0.4s vs ~1.5s for the full 8-message conversation) and strips
    ///   the leading `<bos>` the template re-emits for an isolated
    ///   single-turn render (always safe — `<bos>` is a reserved special
    ///   token id that never appears as ordinary content), plus the
    ///   wrap-overlap amount established by the one-time warm-up parity
    ///   gate (`parityGateOverlap`). Unlike the `<bos>` strip, the
    ///   wrap-overlap strip IS re-verified per call — the tokens about to
    ///   be stripped must equal the warm prefix's corresponding suffix —
    ///   before being trusted; a mismatch falls back to the full render.
    ///   This check is cheap (a small array comparison, not a render), so
    ///   it doesn't defeat the point of this tier the way re-rendering
    ///   would.
    /// - SAFE tier: renders the full conversation exactly as `clean()`
    ///   always did, then feeds only the suffix past the fixed prefix — a
    ///   literal suffix of the real render, so parity is exact by
    ///   construction. Before using the cache, verifies THIS call's
    ///   actual prefix tokens match the warm cache's stored prefix; on any
    ///   mismatch (e.g. an unforeseen tokenizer boundary quirk unique to
    ///   this input) falls back to a fresh, uncached generation for just
    ///   this call — the prefix-cache optimization can only ever speed
    ///   things up, never silently corrupt output.
    private func generateCleaned(
        text: String, chat: [Chat.Message], parameters: GenerateParameters, context: ModelContext
    ) async throws -> String {
        guard let warm = warmPrefix else {
            return try await GemmaBackend.runFreshGeneration(
                chat: chat, parameters: parameters, context: context)
        }

        let inputText: LMInput.Text
        let cache: [KVCache]

        if let wrapOverlap = warm.fastPathWrapOverlap {
            let incremental = try await context.processor.prepare(
                input: UserInput(chat: [.user(CleanupPrompt.wrap(text))]))
            var tokens = incremental.text.tokens.asArray(Int.self)
            if let bos = warm.prefixTokens.first, tokens.first == bos {
                tokens.removeFirst()
            }
            if wrapOverlap > 0 {
                // The warm-up parity gate (`parityGateOverlap`) proved
                // `wrapOverlap` correct only for the two warm-up samples —
                // BPE tokenization at the prefix<->content JOIN is not
                // guaranteed concatenative for every possible input. A
                // leading digit, a leading Spanish "¿"/"¡", a very short
                // single-word utterance, or a leading emoji can tokenize
                // the shared `<start_of_turn>user\n<transcript>\n`
                // open-wrap text differently once it's adjacent to THIS
                // call's specific content, even though the warm-up samples
                // agreed. So verify per call, on the actual token ids,
                // before trusting the strip — never assume it from the
                // one-time warm-up gate alone. Worst case on a mismatch is
                // a slower fallback to the always-correct full render;
                // never a silently wrong prompt.
                //
                // Only the JOIN (prefix tail <-> incremental head) needs
                // this guard. The TAIL side (content + the closing
                // `</transcript>` tag) needs no equivalent check: the
                // isolated single-turn render tokenizes `{text}` and its
                // trailing `</transcript>` together, in-context, in
                // exactly the arrangement fed to the model — there's no
                // seam there for a BPE merge to disagree across, unlike
                // the prefix boundary where two independently rendered
                // pieces (warm prefix + incremental render) are
                // concatenated.
                let toStrip = Array(tokens.prefix(wrapOverlap))
                guard tokens.count >= wrapOverlap,
                    toStrip == Array(warm.prefixTokens.suffix(wrapOverlap))
                else {
                    print("[GemmaBackend] cleanup: fast-path boundary mismatch, using full render")
                    return try await GemmaBackend.runFreshGeneration(
                        chat: chat, parameters: parameters, context: context)
                }
                tokens.removeFirst(wrapOverlap)
            }
            guard !tokens.isEmpty else {
                return try await GemmaBackend.runFreshGeneration(
                    chat: chat, parameters: parameters, context: context)
            }
            // 1-D token array, matching this model's `LLMUserInputProcessor`
            // (no batch dimension) — see `warmUpIfNeeded`'s note.
            inputText = .init(tokens: MLXArray(tokens))
            cache = warm.cache.map { $0.copy() }
        } else {
            let full = try await context.processor.prepare(input: UserInput(chat: chat))
            let fullTokens = full.text.tokens.asArray(Int.self)

            guard fullTokens.count > warm.prefixLen,
                Array(fullTokens[0..<warm.prefixLen]) == warm.prefixTokens
            else {
                print(
                    "[GemmaBackend] prefix mismatch for this call — falling back to uncached generation"
                )
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
            // Honor cleanWithTimeout's cancellation (Pipeline.swift):
            // without this, a timed-out cleanup blocks the task group for
            // the full generation and holds the model mutex.
            try Task.checkCancellation()
            if case .chunk(let piece) = generation {
                output += piece
            }
        }
        return output
    }

    /// Generates without any cache reuse — the exact behavior `clean()`
    /// had before this change (previously via `ChatSession`; this
    /// free-function form is behaviorally identical since `ChatSession`
    /// uses this same `processor.prepare` + `generate` pipeline
    /// internally). Used whenever the warm cache isn't available yet, or a
    /// per-call safety check fails.
    private static func runFreshGeneration(
        chat: [Chat.Message], parameters: GenerateParameters, context: ModelContext
    ) async throws -> String {
        let input = try await context.processor.prepare(input: UserInput(chat: chat))
        let stream = try generate(input: input, parameters: parameters, context: context)
        var output = ""
        for await generation in stream {
            // Same cancellation contract as the warm path above.
            try Task.checkCancellation()
            if case .chunk(let piece) = generation {
                output += piece
            }
        }
        return output
    }

    /// Length of the common leading-token run of two token sequences — the
    /// "two-dummy-query" trick for finding the fixed-prefix boundary
    /// without needing `addGenerationPrompt: false` from the tokenizer
    /// bridge (which isn't publicly exposed). See `warmUpIfNeeded`.
    private static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n] == b[n] {
            n += 1
        }
        return n
    }

    /// Unloading must do three things or the ~2.5 GB stays resident (proved
    /// by MemoryReclaimTests: dropping only the container reclaimed 0 bytes
    /// — mlxCache held ~3 GB and the warm KV-cache pinned ~50 MB live):
    /// 1. Drop the warm-prefix KV-cache — its MLXArrays keep model buffers
    ///    reachable. Cleared inside `container.perform` so it can't race a
    ///    clean() mid-generation (see the class doc on serialization).
    /// 2. Drop the container reference.
    /// 3. Clear MLX's buffer cache — freed Metal buffers otherwise sit in
    ///    its recycling pool forever; they count against phys_footprint
    ///    (Activity Monitor) even though they're invisible to RSS.
    func unload() async {
        if await lazyModel.isLoaded, let container = try? await lazyModel.get() {
            await container.perform { _ in
                self.warmPrefix = nil
                self.warmupAttempted = false
            }
        }
        await lazyModel.unload()
        Memory.clearCache()
    }
    func preload() async { await lazyModel.preload() }
    var isLoaded: Bool { get async { await lazyModel.isLoaded } }
}

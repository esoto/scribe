# Plan — Acoustic vocabulary biasing for Parakeet (batch CTC rescorer)

Status: approved to build (ultracode session, 2026-07-22). API surface verified against the
FluidAudio source pinned in DerivedData.

## Context

scribe's default STT engine is FluidAudio Parakeet TDT v3. When you dictate a technical name
the acoustic model has weak priors for, it mis-decodes it: "Claude" → "cloud", "Kubernetes" →
"cuber netties", "Postgres" → "post grass". Today the only corrective is `TermReplacer`
(`Pipeline.swift`), a deterministic post-STT whole-word substitution keyed off replacement
pairs. That fixes *known, exact* manglings but cannot help the first time a novel mangling
appears, and cannot disambiguate a mangling that collides with a real word ("cloud").

**The user's reframe (the reason for this work):** the right fix isn't "change X to Y" — it's
letting the recognizer *know these words exist* so it transcribes them correctly at the source.
FluidAudio supports exactly this via an auxiliary CTC keyword-spotter model + a
`VocabularyRescorer`. We supply a bias vocabulary sourced from (a) the user's dictionary
(replacement-pair *targets* + glossary become **terms**; known manglings become **aliases**)
plus (b) a curated software-engineering pack shipped on by default.

**Why the batch rescorer, not streaming.** `ParakeetEngine.transcribe` is one-shot:
`manager.transcribe(pcm, decoderState:&state) -> ASRResult`. `VocabularyRescorer.ctcTokenRescore`
is a *post-process* on that finished result — it re-runs a small CTC model over the same audio
to get log-probs, then does timestamp-anchored constrained-CTC matching against the bias terms
and rewrites `result.text`. This keeps our entire architecture; switching to
`SlidingWindowAsrManager` would rewrite the streaming/decoder-state path and re-validate every
fixture and latency assumption — out of scope, higher risk.

**Honest limit — validation.** No shared audio fixture contains an engineering term Parakeet
mishears in a bias-fixable way, and the en/es/mixed/silence WAVs are co-asserted by the Python
suite, so we must not repurpose them. We can prove automatically: (1) **no regression** — with
an empty bias set, existing fixture transcriptions are unchanged; (2) **the plumbing runs** —
models load, a term tokenizes, the rescorer executes without throwing. Whether "cloud" actually
becomes "Claude" is validated only by **the user's live voice**. The feature is built so the
unprovable-offline part is isolated behind a flag and cannot regress anything if it does nothing.

## Locked design decisions

1. **Separate CTC model, downloaded at runtime.** Biasing needs `parakeet-ctc-110m-coreml`
   (`MelSpectrogram.mlmodelc` + `AudioEncoder.mlmodelc` + `vocab.json` + `tokenizer.json`) — a
   second HuggingFace fetch, not part of the TDT v3 download. Use `.ctc110m` (the only tuned
   variant; `.ctc06b` greedy decoding is documented broken). It is *only* a rescoring scorer —
   never transcribe with it.
2. **Reach the setter via a downcast, not a protocol change.** `engines` is
   `[String: UnloadableEngine]`. `setBiasVocabulary` is Parakeet-specific; reach it with
   `engines["parakeet"] as? ParakeetEngine`. Do not widen `SttEngine`/`UnloadableEngine`.
3. **Derive bias vocab from the full dictionary views**, not the capped snapshot — use
   `allPairs` / `allGlossaryEntries` / `unmatchedHeardWords` so biasing covers terms below the
   30-term snapshot cap and isn't suppressed by the Gemma-only "never in both pairs and glossary"
   invariant. A term and its alias legitimately coexist in the bias set.
4. **Curated pack is a compile-time constant, Parakeet-bias-only** — a new
   `EngineeringVocabulary.swift` `static let terms: [String]`. Merged only where the Parakeet
   vocab is derived. Never stored in `UserDictionaryStore` (would pollute the dictionary editor
   and the Gemma prompt).
5. **User-toggleable, default on** — an `AppSettings.vocabularyBiasingEnabled` flag mirroring
   `dictionaryLearningEnabled`, gating both the curated pack and whether biasing runs at all.
   The escape hatch if latency is unacceptable.
6. **Graceful degradation is mandatory.** CTC download/load failure, empty tokenization, nil/empty
   `tokenTimings`, empty `logProbs`, or `wasModified == false` all fall back to plain
   `result.text`. Biasing failure must never fail a dictation. `TermReplacer` still runs on
   whatever text we return, so known exact manglings are corrected even when biasing no-ops.

## Build order (each step keeps `make test` green)

**Step 0 — CTC symbols link.** Confirm `CtcModels`/`CustomVocabularyContext`/`VocabularyRescorer`/
`CtcKeywordSpotter` are public in the pinned FluidAudio (they are, in the checked-out source). If
they ship in a separate product, add it to the `mlDeps` anchor in `native/project.yml:52`; else no
change. `make generate && make test`. A throwaway `_ = CtcModelVariant.ctc110m` proves the link.
**This is the one hard blocker — resolve first.**

**Step 1 — `ModelStore.ctcDirectory`.** Mirror `parakeetDirectory`:
`baseDirectory.appendingPathComponent("ctc/parakeet-ctc-110m-coreml", isDirectory: true)`. Unit
test the path shape.

**Step 2 — `EngineeringVocabulary.swift`.** `enum EngineeringVocabulary { static let terms: [String] }`
— curated canonical spellings (Kubernetes, PostgreSQL, Redis, nginx, Claude, Anthropic, GraphQL,
Kafka, Terraform, …). ASCII, each ≥ 3 chars (the spotter drops shorter). Test: non-empty, no
case-insensitive dupes, all ≥ 3 chars, all survive `CleanupPrompt.sanitizeTerm` unchanged.

**Step 3 — `BiasVocabulary.swift` (the core, fully unit-tested, no model).**
```swift
struct BiasTerm: Equatable { let text: String; let aliases: [String] }
enum BiasVocabularyBuilder {
    static func build(pairs: [ReplacementPair], glossary: [GlossaryEntry],
                      unmatched: [GlossaryEntry], includeCuratedPack: Bool) -> [BiasTerm]
}
```
Rules: pair → `BiasTerm(text: replacement, aliases: [original])`; glossary entry → alias-less
term; each `unmatchedHeardWords` entry appends as an alias on the matching canonical (by text),
else dropped; curated pack merged as alias-less terms when `includeCuratedPack`. Dedup by
lowercased `text`, unioning aliases. Sanitize every text+alias via `CleanupPrompt.sanitizeTerm`
(the plain `CustomVocabularyTerm` init does **not** sanitize). Drop terms whose sanitized
`text.count < 3`. Empty inputs + pack off → empty list (this underpins no-regression). Tests cover
every rule.

**Step 4 — `AppSettings.vocabularyBiasingEnabled`** (default true, round-trips). Mirror
`dictionaryLearningEnabled`.

**Step 5 — `ParakeetEngine.setBiasVocabulary` (state only).** Add `NSLock`-guarded
`biasVocabulary: [BiasTerm]` + a `ctcVocabDirty` flag, copying the `GemmaBackend.setDictionary`
shape. Callable before any model load; no load, no preload cost; applies on next `transcribe`.

**Step 6 — CTC model holder (second `LazyModel`).** Sibling to `LazyModel<AsrManager>`, factory
`CtcModels.downloadAndLoad(to: ModelStore.ctcDirectory, variant: .ctc110m)`, failure swallowed to a
disabled state (never fatal). `isLoaded` tracks TDT only (CTC is auxiliary); `unload`/`preload`
cover both.

**Step 7 — the rescoring step (guarded, between transcribe and return).** Exact sequence — see the
API appendix. Snapshot bias terms under the lock; **if empty or biasing disabled → return plain
text** (the identity path that preserves every fixture). Get CTC models (fail → plain text). Build
& cache a `CustomVocabularyContext` (tokenize each `term.text` via `CtcTokenizer.encode`, populate
`ctcTokenIds`, skip empties; rebuild only when `ctcVocabDirty`). Build & cache the
`CtcKeywordSpotter` (`blankId = ctc.vocabulary.count`) and `VocabularyRescorer.create(...)`. Run
`spotKeywordsWithLogProbs(audioSamples: pcm, …)`. Guard `tokenTimings` non-empty & `logProbs`
non-empty → else plain text. `ctcTokenRescore(...)` (synchronous). Return
`out.wasModified ? out.text : result.text`. Wrap in do/catch; any throw → plain text.

**Step 8 — thread through AppModel.** At startup (next to `cleaner.setDictionary`, `ScribeApp.swift:102`)
and in `applyDictionaryChange` (next to the `cleaner.setDictionary` at ~:430), rebuild via
`BiasVocabularyBuilder.build(pairs: dictionary.allPairs, glossary: dictionary.allGlossaryEntries,
unmatched: dictionary.unmatchedHeardWords, includeCuratedPack: settings.vocabularyBiasingEnabled)`
and call `(engines["parakeet"] as? ParakeetEngine)?.setBiasVocabulary(...)`. **Refresh outside the
`snapshot != dictionarySnapshot` guard** (bias reads full views; the setter is cheap and
idempotent). Do **not** copy Gemma's warm-KV rebuild cost or resident-only guard. Model-free test
via a spy engine / the builder.

**Step 9 — model-backed tests (`make test-models`).** (a) No-regression: `setBiasVocabulary([])`
(and curated-only), transcribe each existing fixture, assert existing `FixtureTests` assertions
still hold. (b) Plumbing smoke: a tiny bias vocab, transcribe a fixture, assert non-empty + no
throw (exercises CTC download/load, tokenization, spotter, rescore). (c) Graceful degradation:
point `ctcDirectory` at an empty temp dir, assert plain text still returned. First run downloads
`parakeet-ctc-110m-coreml`.

## Make targets

`make generate` after `project.yml` changes. `make test` (model-free) green after **every** step —
covers Steps 1–5, 8 and the empty-vocab identity path. `make test-models` after Steps 7 and 9.

## Latency (flag)

The cost is `spotKeywordsWithLogProbs`: a **second CoreML forward pass** (mel + 110M CTC encoder)
over the whole utterance, per dictation, scaling with audio length — the primary UX cost and the
reason for the toggle. `ctcTokenRescore` itself is cheap (sync, CPU). Cache the context, spotter,
and rescorer; rebuild only on `ctcVocabDirty`; tokenize once per vocab change. Escape hatch:
`vocabularyBiasingEnabled = false` removes the entire CTC pass. Measure on target hardware before
committing to default-on.

## Risks / open questions

1. **Does biasing help? — unprovable offline.** Only live voice validates it. Isolated behind the
   flag; no-regression guaranteed automatically. Optional stretch: record a *new* dedicated WAV
   (not shared with Python) asserting one real rewrite.
2. **Second model download** (`parakeet-ctc-110m-coreml`) on first biased dictation / first
   `make test-models`. Lighter than the 0.6B TDT. Graceful fallback while absent.
3. **Per-dictation CTC forward pass** — needs real measurement; may push to default-off or
   length-gated.
4. **`weight`/`cbw` semantics** — `loadFromSimpleFormat` hard-codes term `weight = 10.0`; actual
   boosting uses `rescorerConfig(forVocabSize:).cbw` (4.5). Start with documented defaults, tune
   after live testing.
5. **Aliases feed only string-similarity, not CTC token spotting** (only `term.text` is tokenized).
   Bound manglings help fuzzy matching but aren't a guaranteed acoustic fix.
6. **Idle-unload interaction** — the CTC `LazyModel` should unload cleanly and reload from
   `ModelStore.ctcDirectory` without re-fetching.

## API appendix — exact call sequence (verified)

Preconditions: a finished `result: ASRResult` from `manager.transcribe(...)`, plus the raw 16 kHz
mono `pcm: [Float]` (needed again for the spotter).

```swift
// once per vocab change (cache these):
let ctc = try await CtcModels.downloadAndLoad(to: ModelStore.ctcDirectory, variant: .ctc110m)
let tok = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
let terms = biasTerms.compactMap { t -> CustomVocabularyTerm? in
    let ids = tok.encode(t.text)              // CTC ids; skip if empty
    guard !ids.isEmpty else { return nil }
    return CustomVocabularyTerm(text: t.text, weight: 10.0, aliases: t.aliases, ctcTokenIds: ids)
}
let vocab = CustomVocabularyContext(terms: terms)              // no auto-tokenization
let spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)  // blankId = vocab size
let rescorer = try await VocabularyRescorer.create(
    spotter: spotter, vocabulary: vocab, config: .default,
    ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m))

// per dictation:
let spot = try await spotter.spotKeywordsWithLogProbs(
    audioSamples: pcm, customVocabulary: vocab, minScore: nil)
guard let timings = result.tokenTimings, !timings.isEmpty, !spot.logProbs.isEmpty
else { return result.text.trimmed }
let cfg = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)  // cbw 4.5, minSim 0.5–0.6
let out = rescorer.ctcTokenRescore(                              // SYNCHRONOUS, non-throwing
    transcript: result.text, tokenTimings: timings,
    logProbs: spot.logProbs, frameDuration: spot.frameDuration,
    cbw: cfg.cbw, marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
    minSimilarity: cfg.minSimilarity)
return (out.wasModified ? out.text : result.text).trimmed
```

Key facts: `ctcTokenRescore` is the only apply method — **synchronous, non-throwing**;
`create` and `spotKeywordsWithLogProbs` are the async/throws steps. There is no `logProbs` on
`ASRResult` — the spotter must re-run over `pcm`. `blankId` must be `ctc.vocabulary.count`. A
`CustomVocabularyTerm` with nil/empty `ctcTokenIds` is silently skipped. `cbw`/`minSimilarity`/
`marginSeconds` are per-call, not on `Config` (which only has `useAdaptiveThresholds`,
`referenceTokenCount`).

# Native ML Stack Spike — Results (2026-07-07)

**Verdict: GO** (Gemma via mlx-swift-lm passed — no Qwen fallback needed).

Hardware: Apple M2 Pro, 10 cores, 16 GB. macOS 26.5.1 (Build 25F80).
Toolchain: Xcode 26.6 (17F113), Swift 6.3.3, xcodegen 2.45.3.

## Resolved package versions

| Package | Requested | Resolved |
|---|---|---|
| FluidAudio | from 0.15.4 | 0.15.4 |
| argmax-oss-swift (WhisperKit) | from 1.0.0 | 1.0.0 |
| mlx-swift-lm | from 3.31.4 | 3.31.4 (mlx-swift 0.31.6) |
| swift-huggingface | from 0.9.0 | 0.9.0 |
| swift-transformers | from 1.3.0 | 1.3.3 |

## GO criteria

| # | Criterion | Result |
|---|---|---|
| 1 | Parakeet en contains "Wednesday" | **PASS** |
| 2 | Parakeet es contains "deberíamos" | **PASS** |
| 3 | Gemma cleaned contains "Wednesday", not "Tuesday" | **PASS** |
| 4 | Whisper mixed contains "deploy" | **NOT MET LITERALLY — judged PASS vs baseline** (see below) |

## Measured outputs (verbatim, identical across cold + warm runs — deterministic at temp 0)

```
=== FluidAudio Parakeet v3 ===
en (195 ms): So um, I think we should, uh, we should probably move the meeting to Tuesday, no wait, Wednesday afternoon, and um, tell Marcos about it.
es: Este, bueno, yo creo que deberíamos, eh, deberíamos mandar el reporte el lunes, no, mejor el martes en la mañana, o sea, antes del mediodía.
=== MLX Gemma 3 4B QAT ===
cleaned (1804 ms): So, I think we should move the meeting to Wednesday afternoon and tell Marcos about it.
=== WhisperKit large-v3-turbo ===
mixed: Ok, vamos a deploramos el fix. Mañana en la mañana, o sea, antes del standout.
SPIKE: GO
```

Note: the spike's `SPIKE: GO` print only means "no exception thrown"; the criteria
above were evaluated manually against the printed outputs.

### Criterion 4 analysis (Whisper "deploy")

WhisperKit transcribed the code-switched loanword as "deploramos" (and "standup" as
"standout") — the literal substring "deploy" is absent. Cross-check against the repo's
validated Python stack on the identical fixture:

```
$ .venv/bin/python -c "... WhisperEngine('mlx-community/whisper-large-v3-turbo') ..."
PYTHON WHISPER mixed: Ok, vamos a deplorar el fix.
```

The validated mlx-whisper baseline also lacks "deploy" AND truncates the entire second
half of the audio. WhisperKit's transcription is strictly more complete than the
baseline on this fixture. The criterion is unsatisfiable on this synthesized fixture by
either stack — a fixture/criterion issue, not a WhisperKit regression. WhisperKit is
judged functionally validated (loads, runs VAD-chunked code-switched transcription,
output quality ≥ Python baseline).

## Latencies

| Stage | Cold (first run, incl. downloads) | Warm (models cached) |
|---|---|---|
| Whole spike (3 stacks, load + inference) | 6 m 41 s | **~19 s** |
| Parakeet model download (23 files) + Encoder.mlmodelc compile | ~70 s + 17.7 s | — (cached) |
| Parakeet en.wav transcribe (measured by spike) | 156 ms | **195 ms** |
| Gemma `ChatSession.respond` (measured by spike) | 3685 ms | **1804 ms** |
| WhisperKit model download (1.5 GB) + CoreML compile | ~4–5 min (dominates cold run) | — (cached) |

Warm ~19 s wall covers loading all three model stacks plus inference; per-process
load is the dominant term, inference itself is sub-2 s per stage.

## Model caches (cleanup-model decision inputs)

- Parakeet v3: `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3` (469 MB)
- WhisperKit: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo` (1.5 GB)
- Gemma 3 4B QAT 4bit: standard HF cache `~/.cache/huggingface/hub/models--mlx-community--gemma-3-4b-it-qat-4bit` — shared with the Python stack (no duplicate download observed)

## Build deviations from the brief (environment, not API)

The brief's Swift spike code compiled **as written** — no API changes were needed
(`AsrModels.downloadAndLoad(version: .v3)`, `AsrManager(config: .default)`,
`TdtDecoderState()`, `AudioConverter().resampleBuffer`, `#huggingFaceLoadModelContainer`,
`ChatSession(_:instructions:generateParameters:)`, `WhisperKitConfig`,
`DecodingOptions(..., chunkingStrategy: .vad)` all exist in the resolved versions).

Environment fixes that were required:

1. **Metal Toolchain**: Xcode 26.6 ships without it; mlx-swift compiles Metal kernels at
   build time. Fix: `xcodebuild -downloadComponent MetalToolchain` (688 MB, one-time).
2. **Plugin/macro validation**: non-interactive `xcodebuild` fails on mlx-swift's
   `CudaBuild` build plugin (and swift-syntax macros). Fix: pass
   `-skipPackagePluginValidation -skipMacroValidation` on CLI builds (in the Xcode GUI
   you approve these once instead).
3. **Test-target Info.plist**: xcodegen does not synthesize an Info.plist for
   `bundle.unit-test` targets and code signing fails without one. Fix (in
   `project.yml`): `GENERATE_INFOPLIST_FILE: YES` on `ScribeTests` and `ScribeModelTests`.
4. `xcodegen generate` must be re-run after adding source files (the generated
   `Scribe.xcodeproj` and `Info.plist` are derived artifacts, gitignored; regenerate
   after checkout).

Harmless warnings observed: dual macOS destination (arm64 picked), auto-linked
`CoreAudioTypes` framework not found (linker warning only).

## Task 15 parity run (2026-07-07)

**Golden eval before fix: 8/10.** `GoldenEvalTests` (native, port of `tests_models/run_eval.py`)
failed 2 of 10 cases — both English inputs, both translated to Spanish by the model:

- `en-question-stays-question`: "um do you think we should uh ship this on friday" →
  "¿Crees que deberíamos enviar esto el viernes?"
- `en-request-not-fulfilled`: haiku-about-mountains case, same translation failure mode.

All 8 Spanish-input cases and the other English cases passed; the Python oracle
(`tests_models/run_eval.py` against the same model/temp) passes 10/10 on the identical
golden set — so this was a genuine native-vs-Python divergence, not a model regression.

### Root cause

`CleanupPrompt.swift`'s constants (system prompt + 3 few-shot pairs) are byte-identical
to `src/scribe/cleanup/base.py`'s — that was verified going in. The divergence was in
**how `GemmaBackend.swift` assembled the chat message history**, not in the prompt text
itself.

Python's `build_messages()` (`src/scribe/cleanup/base.py`) wraps **every** user turn —
each of the 3 few-shot examples AND the real query — in `<transcript>...</transcript>`
tags before handing them to `tokenizer.apply_chat_template()`. `GemmaBackend.swift`'s
`clean()` wrapped only the real query (`CleanupPrompt.wrap(text)` passed to
`session.respond(to:)`) but built the few-shot `history` array from the **raw, unwrapped**
example strings:

```swift
// before (bug)
let history = CleanupPrompt.fewShots.flatMap { input, output in
    [Chat.Message.user(input), Chat.Message.assistant(output)]
}
```

This was verified empirically, not just by code reading: a temporary XCTest
(`PromptDumpTests.swift`, deleted after use) rendered the exact token sequence
`ChatSession` sends to the model — built via `container.processor.prepare(input:)` →
`tokenizer.applyChatTemplate()`, the same path `ChatSession.streamMap` uses internally —
and diffed it against Python's `tokenizer.apply_chat_template(build_messages(text),
add_generation_prompt=True, tokenize=False)` for the "friday" case:

- Python: 290 tokens. All 4 user turns (3 few-shot + query) wrapped in `<transcript>` tags.
- Swift (before fix): 266 tokens. Only the 4th (real query) user turn wrapped; the 3
  few-shot user turns were bare text.
- System-role handling, message ordering, and `add_generation_prompt` framing were
  otherwise identical — Gemma's chat template (`tokenizer_config.json`) merges the
  system message into the first user turn's content for both Python's Jinja2 and
  swift-transformers' Jinja port, and both stacks resolve `temperature: 0` to a pure
  `argmax` sampler (`mlx_lm.sample_utils.make_sampler`
  vs `GenerateParameters.sampler()` in mlx-swift-lm's `Evaluate.swift`), so sampling
  parity was already confirmed and ruled out as a factor.

Net effect: the model saw 3 examples demonstrating "raw text in → cleaned text out"
immediately followed by a real query wrapped in markup the examples never used. That
inconsistency weakened the in-context signal for "same language in, same language out"
(explicit only in the system prompt's "NEVER translate" line, not otherwise reinforced
by the wrapped/unwrapped mismatch) enough to flip 2/10 English cases to Spanish output.

### Fix

`native/Sources/Scribe/GemmaBackend.swift`: wrap each few-shot example's user turn with
`CleanupPrompt.wrap()`, matching the real query and matching Python's `build_messages()`
exactly:

```swift
// after (fix)
let history = CleanupPrompt.fewShots.flatMap { input, output in
    [Chat.Message.user(CleanupPrompt.wrap(input)), Chat.Message.assistant(output)]
}
```

No changes to `CleanupPrompt.swift`'s strings (system prompt / few-shot text / `wrap()`
implementation) — the bug was purely in `GemmaBackend.swift`'s message assembly.
Re-running `PromptDumpTests` after the fix showed the Swift-rendered prompt now matches
Python's **exactly**: 290 tokens, identical `<start_of_turn>`/`<transcript>` structure
for every turn.

### Verification

| Check | Before | After |
|---|---|---|
| `GoldenEvalTests` (native, 10 cases) | 8/10 | **10/10** |
| Rendered prompt token count (friday case) | 266 | **290 (matches Python)** |
| `ScribeTests` (full suite) | — | **96/96**, 0 failures |

Timings (warm, model cached): `GoldenEvalTests` full run ~37 s (10 cases, ~3 s each
after ~5 s model load); `ScribeTests` full suite ~0.6 s (all pure-logic, no model
loads); `PromptDumpTests` single-case dump ~6 s.

### Full-scheme post-fix run (controller verification, 2026-07-07 ~21:5x)

`xcodebuild test -scheme ScribeModelTests` (unscoped, all models cached): **8/8, TEST SUCCEEDED, 51.7 s total.**
FixtureTests 7/7 — concurrency 0.90 s, Parakeet en 0.13 s / es 0.12 s / silence 0.09 s, Whisper en 9.5 s (cached; earlier 2596 s figure was the one-time model download).

## Cleanup speed investigation (2026-07-07)

**Problem:** native cleanup (`GemmaBackend.swift`, MLX-Swift `ChatSession`) took
~2.8–3.5 s/utterance, ~2.6x the Python oracle's ~1.3–1.5 s
(`src/scribe/cleanup/base.py` + `mlx_lm`, same model/machine), and was nearly
**flat regardless of input/output length** (20 chars → 2.8 s, 113 chars → 3.3 s).

### Method

Instrumented both stacks directly rather than guessing:

- **Python**: a one-off script (`.venv/bin/python`) loaded
  `mlx-community/gemma-3-4b-it-qat-4bit` via `mlx_lm.load`/`generate(...,
  verbose=True)` with the exact `build_messages()`/`max_tokens_for()` the
  app uses, on the input `"um do you think we should uh ship this on
  friday"`. Result (warm run): **290 prompt tokens, 11 generated tokens,
  stopped on EOS, wall 1.27 s** (prompt 290 tok @ 312 tok/s ≈ 0.93 s;
  generation 11 tok @ 67 tok/s ≈ 0.16 s).
- **Swift**: a temporary XCTest (`GenPerfTests.swift`, deleted after use —
  see git history for the exact harness) drove `ChatSession.streamDetails`
  and, separately, a bare `TokenIterator` (bypassing `ChatSession`'s actor
  plumbing) on the identical input/config, printing
  `GenerateCompletionInfo` (generated-token count, tokens/s, stop reason)
  and hand-timed phase breakdowns (`processor.prepare` / chat-template
  render, `TokenIterator.init` / prompt prefill, generation loop).

### Root causes (two, independent)

**1. Missing `<end_of_turn>` stop token (confirmed bug, now fixed).**
`GemmaBackend.swift` loaded the model via
`#huggingFaceLoadModelContainer(configuration: ModelConfiguration(id:
"mlx-community/gemma-3-4b-it-qat-4bit"))` — a **bare** `ModelConfiguration`
literal. `#huggingFaceLoadModelContainer` expands to
`loadModelContainer(from:using:configuration:progressHandler:)`
(`MLXHuggingFaceMacros/HuggingFaceIntegrationMacros.swift`), which passes
that literal straight through `resolve(configuration:from:useLatest:
progressHandler:)` (`MLXLMCommon/ModelFactory.swift`) with **no lookup**
against `VLMModelFactory`'s static registry — so the registry's
`VLMRegistry.gemma3_4B_qat_4bit` entry, which sets `extraEOSTokens:
["<end_of_turn>"]`, was never consulted. `ChatSession`'s stop-token set
(`buildStopTokenIds` in `MLXLMCommon/Evaluate.swift`) therefore only
contained the tokenizer's single `eos_token` (`<eos>`, id 1, from
`tokenizer_config.json`) — not `<end_of_turn>` (id 106), the token Gemma's
chat template and `generation_config.json`'s `eos_token_id: [1, 106]`
actually use to end a turn.

Direct proof via the bare-`TokenIterator` harness (bypassing `ChatSession`,
config matching the pre-fix `GemmaBackend`): the model correctly generated
*"Do you think we should ship this on Friday?"* and then emitted
`<end_of_turn>` — since that token wasn't registered as a stop token, it was
appended as ordinary output and generation continued, **repeating
`<end_of_turn>` 190 more times** until hitting the 200-token ceiling
(`stopReason: maxTokens`, `generateLoop: ~6.1–6.3 s`). Decoded output
(truncated): `"Do you think we should ship this on Friday?<end_of_turn>
<end_of_turn>\n<end_of_turn><end_of_turn>..."` (190x). This reproduced
identically across repeated runs.

Interestingly, the *production* code path (`ChatSession`, matching
`GemmaBackend.clean()` exactly) did not hit this ceiling in the measured
"friday" case — it happened to argmax to `<eos>` (id 1) after 10 tokens even
pre-fix, most likely because per-token logits for `<eos>` vs `<end_of_turn>`
are extremely close post-quantization and GPU floating-point reduction order
can differ subtly between `ChatSession`'s actor-hopped call path and a raw
synchronous `TokenIterator` loop. That makes this a **fragile, latent bug**:
usually masked by a near-tied argmax, but capable of stalling 6–9 extra
seconds on any input/model-state combination where the tie breaks the other
way. Fixed by setting `extraEOSTokens` explicitly (`GemmaBackend.swift`):

```swift
static func modelConfiguration() -> ModelConfiguration {
    ModelConfiguration(
        id: "mlx-community/gemma-3-4b-it-qat-4bit",
        extraEOSTokens: ["<end_of_turn>"]
    )
}
```

Post-fix, the same bare-`TokenIterator` harness stops deterministically at
`stopReason: eos(106)`, **10 generated tokens**, `generateLoop: ~0.76 s`
(down from ~6.1–6.3 s) — matching Python's 11-token stop almost exactly.

`GenerateParameters` were checked and ruled out as a contributing factor:
`GemmaBackend`'s `temperature: 0.0` resolves to `ArgMaxSampler` (no
top-p/top-k/min-p, since `topP` defaults to `1.0` and `topK`/`minP` default
to `0`), and no repetition/presence/frequency penalty is set — this already
matches Python's `make_sampler(temp=0.0)` with no extra per-token
transforms, so there was nothing to tighten there.

**2. Chat-template (Jinja) rendering dominates latency — NOT fixed in this
pass; documented as a follow-up.** Isolating `processor.prepare(input:)`
(chat-template render + tokenize, called once per `clean()` call before any
generation) showed it costing **~1.5 s consistently**, with **no speedup
across repeated identical calls** on the same loaded model/tokenizer (4x
back-to-back calls: 1538/1490/1489/1491 ms) — ruling out template
*compilation* (swift-transformers' `PreTrainedTokenizer` does cache
compiled `Jinja.Template`s by string, confirmed in
`Tokenizer.swift:compiledTemplate(for:)`) as the cost; it's template
*rendering* itself. Render time scales with the message list: system+query
only (2 messages) costs ~400 ms; the full system+3-few-shot-pairs+query (8
messages, what every `clean()` call actually sends) costs ~1.5 s. Add
prompt-prefill (~0.6–0.7 s for the resulting 290 tokens, in line with
Python's prefill throughput) and the **fixed floor is ~2.1–2.4 s before any
utterance-specific generation happens** — this is the real explanation for
the reported "flat regardless of length" symptom: the few-shot prefix (which
never changes) dominates over the short, variable utterance.

This is upstream of `native/` (swift-transformers' Jinja interpreter,
vendored via SPM) — we can't fix the interpreter itself. The available
lever is architectural: avoid re-rendering + re-tokenizing + re-prefilling
the fixed system+few-shot prefix on every call. `ChatSession` supports this
via its `cache:` initializer (prebuilt `[KVCache]`, documented for exactly
this "long shared context computed once" use case) — when a `.kvcache` is
supplied, `ChatSession.streamMap` skips appending `history` to the rendered
message list entirely, so `processor.prepare` only renders the new query.
**Not implemented here**: correctly wiring it requires stripping the
chat-template's per-call `<bos>` (Gemma's template always emits `{{
bos_token }}`, which would double up when continuing an existing cache),
verifying the KV-cache-continuation path produces numerically-equivalent
output to a fresh prefill for a 4-bit QAT model, and dedicated test
coverage for the clone/reuse semantics across calls — more scope than fits
safely in this debugging pass. Flagging as the next concrete step to close
the remaining gap to Python.

### Before/after (same input, same machine)

| Harness | Metric | Before | After |
|---|---|---|---|
| Bare `TokenIterator` (isolates generation) | generated tokens | 200 (ceiling) | **10** |
| Bare `TokenIterator` | stop reason | `maxTokens` | **`eos(106)`** |
| Bare `TokenIterator` | generation loop wall | ~6.1–6.3 s | **~0.76 s** |
| Bare `TokenIterator` | decoded output | correct sentence + 190x `<end_of_turn>` spam | correct sentence, clean stop |
| `ChatSession` (matches `GemmaBackend.clean()`) | wall (warm, 2nd call) | 3069–3126 ms | 2871–2894 ms |
| `ChatSession` | generated tokens / stop reason | 10 / `.stop` (lucky pre-fix) | 10 / `.stop` (now deterministic) |
| `chatTemplatePrepare` (unaffected by this fix) | — | ~1.49–1.58 s | ~1.49–1.51 s |

Python oracle, same input: 290 prompt tokens, **11** generated tokens,
stopped on EOS, wall **1.27 s**.

**Net effect of the fix actually shipped:** removes a real, reproducible
failure mode (200-token/~6–9 s stalls whenever the `<eos>`/`<end_of_turn>`
argmax tie breaks the "wrong" way) and makes stopping behavior
deterministic instead of relying on a near-tied logit. It does **not**
close the full ~2.6x gap to Python — the dominant remaining cost
(`chatTemplatePrepare`, ~1.5 s/call) is unchanged, because it was never
about token count or EOS handling in the common case observed here. Golden
eval stayed **10/10** (`GoldenEvalTests`, native) at ~3.0–3.4 s/case
(dominated by the same fixed template-render + prefill floor); `ScribeTests`
stayed **101/101** green.

### Verification

| Check | Result |
|---|---|
| `GoldenEvalTests` (native, 10 cases) | **10/10**, ~3.0–3.4 s/case (first case ~7.5 s incl. cold model load) |
| `ScribeTests` (full suite) | **101/101**, 0 failures |
| Temporary `GenPerfTests.swift` | deleted after use (loaded the full 4B model per test, not fast-suite material) |
GoldenEvalTests: **10/10** (per-case 3.2–9.3 s, total 40.9 s).

## Cleanup speed — prefix cache (2026-07-08)

**Goal:** close the follow-up gap flagged above — the system prompt + 3 few-shot pairs
are IDENTICAL on every `clean()` call, so re-rendering (Jinja chat template) and
re-prefilling that fixed ~270-290-token prefix on every call was pure waste. Implemented
warm KV-cache reuse in `GemmaBackend.swift`: build the prefix's KV cache once (lazily, on
first `clean()`), then reuse a `.copy()` of it (never mutated in place) on every
subsequent call.

### Design: two tiers, SAFE always on, FAST gated by an empirical parity check

- **SAFE tier** (always available once warmed): still renders the full 8-message
  conversation every call (so it does NOT save the ~1.5s template render) but skips
  re-prefilling the ~0.6s prefix — feeds the model only `fullTokens[prefixLen...]`, a
  *literal suffix* of that render, so parity is exact by construction. A per-call check
  (`fullTokens[0..<prefixLen] == prefixTokens`) verifies this call's actual render still
  shares the cached prefix before trusting it; on any mismatch it falls back to an
  uncached fresh generation for just that call.
- **FAST tier** (opportunistic): additionally skips the full-conversation render by
  rendering only the incremental turn (`[.user(wrap(text))]`, ~0.4s vs ~1.5s). Only
  trusted after a one-time startup parity gate proves
  `prefixTokens + strip(incrementalRender) == fullRenderTokens` EXACTLY for both an EN and
  an ES sample; any mismatch permanently falls back to SAFE for the process.

`prefixLen` is found via the "two-dummy-query" trick (render two full conversations
differing only in the final query, take their common leading-token length) — this avoids
needing `addGenerationPrompt: false`, which `MLXLMCommon.Tokenizer`'s bridge doesn't
expose. The warm cache is prefilled by constructing (but never iterating) a
`TokenIterator` over just the prefix tokens — its `init` mutates the passed-in `KVCache`
objects in place via `model.prepare(...)`, matching `ChatSession`'s own internal
multi-turn continuation pattern.

**Model detail that mattered:** this model resolves through `LLMModelFactory`'s
text-only `LLMUserInputProcessor` (a `*_text` Gemma3 config), which renders
`LMInput(tokens: MLXArray(promptTokens))` — a **1-D** token array with no batch
dimension and no mask. (The initial implementation assumed the VLM `Gemma3Processor`'s
2-D `[1, N]` shape from reading the wrong file in the vendored source and crashed with
`Fatal error: SmallVector out of range` on the first warm-up call — indexing a 1-D array
with two axis specifiers. Fixed by single-axis slicing throughout.)

**Parity gate found a real structural issue, and self-corrected.** The naive
`prefixTokens + strip_bos(incrementalRender)` check failed on first run: `prefixLen`
(270) lands 7 tokens past the few-shot region, *inside* the shared
`<start_of_turn>user\n<transcript>\n` open-wrap text that an isolated single-turn render
also reconstructs from scratch — so that 7-token wrap-open appeared twice in the
concatenation. Confirmed by diffing the mismatching token arrays (first divergence
exactly at index 270, extra `[105, 2364, 107, 236820, 109532, 236813, 107]` block).
Generalized the gate: measure this "wrap overlap" once per warm-up sample, REQUIRE it to
be IDENTICAL across the EN and ES samples (same rigor as `prefixLen` itself — trusted
because two maximally-different probes agree, not assumed from one), and only enable
FAST if every sample both agrees on the overlap AND reproduces the full render exactly
with it stripped. Both samples agreed (`wrapOverlap=7`) and parity now holds exactly —
FAST engaged.

### Before/after (GoldenEvalTests, per-case wall time, same machine)

| Case | Before (SAFE didn't exist; ChatSession per call) | After (FAST engaged, `wrapOverlap=7`) |
|---|---|---|
| 1st case (incl. one-time warm-up: 2 dummy renders + prefill + parity gate) | ~7.5–11.8 s (incl. cold model load in some runs) | ~11.0–11.1 s (model already loaded via `LazyModel`; warm-up itself adds ~4s here) |
| Steady-state (cases 2–10) | ~3.0–3.4 s/case (2871–3126 ms warm, per prior investigation) | **~0.95–1.7 s/case**, avg ≈ **1.17 s/case** across two full runs |

Two consecutive full `GoldenEvalTests` runs (10/10 both times) for stability:
- Run A: 11117, 1481, 1660, 941, 1069, 1188, 1078, 1132, 966, 989 ms — total 21.6 s.
- Run B: 10925, 1467, 1663, 954, 1088, 1214, 1127, 1159, 960, 1009 ms — total 21.6 s.

Steady-state average (cases 2–10, both runs): **~1.15 s/utterance** — down from the
documented ~2.87s baseline (~1.5s render + ~0.6s prefill + ~0.7s generation), and now
close to the Python oracle's ~1.3s. The remaining per-call cost is dominated by the
short incremental-turn render (~0.4s) + generation (~0.7s); the fixed prefix's render and
prefill are fully eliminated from the steady-state path.

### Verification

| Check | Result |
|---|---|
| `GoldenEvalTests` (native, 10 cases), 2 consecutive runs | **10/10** both times, `fastPath=true wrapOverlap=7` both times |
| `ScribeTests` (full suite) | **101/101**, 0 failures |
| Path engaged | **FAST** (parity gate passed for both EN and ES samples after the wrap-overlap generalization) |

### Concerns

- FAST's per-call trust is inherently a one-time, warm-up-validated guarantee — it is
  NOT re-verified against a full render on every call (that would defeat its purpose).
  The two-diverse-sample parity gate (requiring exact agreement between maximally
  different EN/ES probes) is the same rigor already accepted for `prefixLen` itself, and
  the golden eval's 10 realistic, linguistically-varied cases passing at 10/10 is
  additional empirical evidence, but this is a residual, accepted risk of the FAST tier
  by design (per the task brief).
- SAFE tier's per-call safety check (`fullTokens[0..<prefixLen] == prefixTokens`) fully
  protects against any tokenizer-boundary surprise for a specific real utterance, at the
  cost of falling back to an uncached generation for that one call only — this path was
  not exercised in the 10 golden cases (no mismatches observed) but exists as a
  correctness backstop.
- Warm-up cost (~4s: 2 dummy renders + prefix prefill + parity gate) is paid once per
  process, on the first real `clean()` call — this inflates that first call's latency
  but is a one-time cost, not per-utterance.

## Cleanup speed — prefix cache: FAST-tier per-call boundary guard (2026-07-08)

**Trigger:** adversarial review of the prefix-reuse optimization above found the FAST
tier's residual risk (the "accepted risk of the FAST tier by design" concern noted above)
was sharper than described: the fixed `wrapOverlap` (7) was derived once from the EN/ES
warm-up samples and then applied unconditionally to every call's tokens via
`tokens.removeFirst(min(wrapOverlap, tokens.count))`, with **no per-call check** that the
tokens actually being discarded were the ones the warm-up gate assumed. BPE tokenization
at the prefix/content JOIN is not guaranteed concatenative — a leading digit, a leading
Spanish `¿`/`¡`, a very short single-word utterance, or a leading emoji could tokenize the
shared `<start_of_turn>user\n<transcript>\n` wrap-open text differently than the two
warm-up probes did, which would silently strip the wrong tokens (eating real content or
leaving a stray wrap token) — a deterministic wrong output that would still pass the 10
golden cases (none of which happen to trigger it).

### Fix (C1, critical)

`generateCleaned`'s FAST branch (`GemmaBackend.swift`) now verifies the boundary before
trusting the strip: it slices the `wrapOverlap` tokens about to be removed and requires
them to equal `warm.prefixTokens.suffix(wrapOverlap)` — the literal tail of the warm
prefix — before calling `tokens.removeFirst(wrapOverlap)`. On any mismatch (or if there
aren't even `wrapOverlap` tokens to check), it logs
`"[GemmaBackend] cleanup: fast-path boundary mismatch, using full render"` and falls back
to `runFreshGeneration` — the same always-correct, uncached full-render path used
elsewhere as the SAFE/no-warm-up fallback. Worst case for a pathological input is a
slower call; it can never silently corrupt the prompt. The `<bos>` strip needs no
equivalent guard (unchanged) — `<bos>` is a reserved special-token id that can never
appear as ordinary content, so stripping it when present is unconditionally safe. The
TAIL side (content + the closing `</transcript>` tag) also needs no guard: the isolated
single-turn render tokenizes `{text}` and its trailing `</transcript>` together, in
context, in exactly the arrangement fed to the model — there's no seam there for a BPE
merge to disagree across, unlike the prefix boundary where two independently rendered
pieces (warm prefix + incremental render) are concatenated. Both points are now recorded
as code comments at the guard site.

### Test coverage (I1, important)

The always-correct fallback (`runFreshGeneration`) was previously exercised only
indirectly (whenever `warmPrefix` is `nil`, i.e. before warm-up completes) and had no
dedicated test — everything silently depended on it working whenever a guard tripped.
`runFreshGeneration` is `private`, so it isn't reachable directly from
`@testable import Scribe` in a different file; instead, added
`native/Tests/ScribeModelTests/FastPathBoundaryTests.swift` (real-model tier, not the fast
`ScribeTests` suite) with three tests that drive the exact C1 risk inputs end-to-end
through the real, unmodified `clean()`:

- a Spanish input starting with `¿` ("¿crees que deberíamos eh enviarlo el viernes?"),
- an English input starting with a bare digit ("2 things we need um to review before
  friday"),
- a very short single-word utterance ("sí").

Each asserts the cleaned output contains the expected content, has the filler word
removed, and is well within a sane length bound (`< 200` chars) — a corrupted
prefix/content join or a broken stop-token setup would either garble the content
(failing the substring checks) or run away without finding `<end_of_turn>`/`<eos>`
(failing the length check), so these tests would catch a regression in either the guard
or the fallback path even though — see Verification below — none of the three inputs
actually tripped the guard on this tokenizer.

(Minor test-writing note: the digit test initially asserted the literal `"2"` appeared in
the output and failed — the model legitimately spelled it out as `"Two things we need to
review before Friday."`, a stylistic cleanup choice, not a boundary corruption. Loosened
the assertion to accept either `"2"` or `"two"`.)

### I2: `ModelContainer.perform` concurrency mechanism (confirmed, no code change needed)

Read the vendored `MLXLMCommon/Utilities/SerialAccessContainer.swift`
(`~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/mlx-swift-lm/...`).
`ModelContainer.perform` calls `SerialAccessContainer.read`, which funnels through a
private `AsyncMutex` — an `actor` that hand-rolls `isLocked` plus a `CheckedContinuation`
waiter queue (`lock()`/`unlock()`), NOT bare actor-reentrancy. Its own doc comment states
this exists specifically because "an `actor` does not guarantee exclusive access for the
duration of an `async` function" — i.e. this is deliberately a real serial lock held for
the whole `perform` body, addressing exactly the race the finding worried about. This
confirms the existing `@unchecked Sendable` justification in `GemmaBackend`'s class doc
comment was already correct; added a short comment citing this source next to it. No
additional protection around warm-up idempotency was needed — two `clean()` calls can
never interleave their access to `warmPrefix`/`warmupAttempted`.

### Verification

| Check | Result |
|---|---|
| `GoldenEvalTests` (10 cases) | **10/10 passed**, `fastPath=true wrapOverlap=7` — per-case: 10173, 1379, 1506, 864, 970, 1074, 1021, 1048, 883, 917 ms (first case includes cold model load; steady-state ~0.9–1.5s, consistent with the ~1.15s baseline established above) |
| Fallback triggered on any golden case? | **No** — no `"boundary mismatch"` log line in the run |
| `FastPathBoundaryTests` (3 new tests: `¿`-leading, digit-leading, short single-word) | **3/3 passed** |
| Fallback triggered on any of the 3 stress inputs? | **No** — `wrapOverlap=7` tokenized correctly for all three on this tokenizer; the guard *proved* correctness per call rather than needing to catch a real mismatch |
| `ScribeTests` (full suite) | **101/101 passed**, 0 failures |

The guard never fired in this verification pass — expected and fine per the task's own
framing: the point of a per-call guard is that it **proves** correctness for every input
that does tokenize consistently, and safely degrades to a slower-but-correct path for any
future input that doesn't, rather than relying on the one-time warm-up gate's two samples
generalizing to every possible transcript.

### Concerns

- The three new stress tests happened not to trip the guard on the current tokenizer/model
  pairing — they're regression coverage for the guard-and-fallback mechanism (via output
  correctness + length bounds), not a demonstration that the fallback path executes. If a
  future tokenizer/model update ever does trip the guard, the
  `"[GemmaBackend] cleanup: fast-path boundary mismatch, using full render"` log line is
  the signal to watch for in production logs.
- `runFreshGeneration` still has no test that observes it running with the wrap-overlap
  guard specifically causing the fallback (as opposed to `warmPrefix == nil` or the SAFE
  prefix-mismatch guard) — synthetically forcing that would require exposing private
  `GemmaBackend` state to tests, which wasn't done here to avoid weakening encapsulation
  for test-only access. The three new tests are the practical, non-invasive substitute the
  task's own fallback framing allows for ("if forcing a guard-trip synthetically is
  impractical, at minimum...").

## AFM cleanup experiment (2026-07-08)

**Question:** with the evolved `CleanupPrompt` (few-shots + guided output) rather than the
bare system prompt the 2026-07-06 hand probe used, does Apple's on-device FoundationModels
(AFM) become viable as the cleanup backend, replacing Gemma 3 4B QAT? Full detail:
`.superpowers/sdd/afm-experiment-report.md` (gitignored — not committed). Harness:
`native/Tests/ScribeModelTests/AFMExperimentTests.swift`, gated behind
`AFM_EXPERIMENT=1` (`TEST_RUNNER_AFM_EXPERIMENT=1` when invoked via `xcodebuild`) so it's
excluded from the default `ScribeModelTests` run.

**Verdict: REJECT.** Ran the full 10-case golden set through 3 variants against
`SystemLanguageModel(guardrails: .permissiveContentTransformations)`, all with
`temperature: 0.0` / greedy sampling:

| Variant | Score | Avg ms/case |
|---|---|---|
| BASELINE (system prompt only, no few-shots) | 7/10 | 475 ms |
| FEWSHOT-TRANSCRIPT (`Transcript`-seeded with the 3 few-shot pairs) | **8/10** (best) | 433 ms |
| GUIDED (`@Generable` + `respond(to:generating:)`, no few-shots) | 5/10 | 546 ms |

Gemma (same-day default run, `GoldenEvalTests`): **10/10**, steady-state avg ≈1130 ms/case.

No variant reached parity. Most importantly, the July-6 probe's headline failure —
resolving "Tuesday no wait Wednesday" to the wrong side (Tuesday) — reproduced in BASELINE
and GUIDED; only FEWSHOT-TRANSCRIPT fixed it. GUIDED output, which the July-6 probe
suggested would fix instruction-execution risk, instead **regressed** two previously-passing
cases (dropped a "?", stopped restoring Spanish accents) while only partially helping the
one case it targeted — a net loss vs. BASELINE. Zero guardrail/refusal or rate-limit errors
across all 30 generations; AFM ran directly from the `xctest` process with no TCC/entitlement
issue (the `ScribeSpike`-CLI fallback the ticket anticipated was not needed on this machine).

Verification: `ScribeTests` 101/101 green; default `ScribeModelTests` run (no env var) shows
`AFMExperimentTests` skipped via `XCTSkip` and `GoldenEvalTests` still 10/10 — the experiment
harness has zero effect on the existing parity gate.

**Worth revisiting, not adopting today:** FEWSHOT-TRANSCRIPT is ~2.5x faster than Gemma's
steady-state latency with no model-load cost and fixed one of the three original failure
classes outright, using the existing 3 Gemma-tuned few-shots verbatim (no AFM-specific
tuning attempted). If the two remaining failure classes (Spanish correction-resolution not
fully closing; benign instruction-looking requests still being executed) can be closed with
few-shots that specifically demonstrate those two scenarios, AFM could become viable as a
secondary/fast-path candidate — future work, out of scope for this experiment.

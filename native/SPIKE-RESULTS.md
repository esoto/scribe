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

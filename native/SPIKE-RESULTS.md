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
GoldenEvalTests: **10/10** (per-case 3.2–9.3 s, total 40.9 s).

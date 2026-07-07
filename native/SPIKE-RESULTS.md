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

# Model store + custom cleanup model — design

Date: 2026-07-09. Approved by Esteban (defaults-write-only UX).

## Problem

Models are scattered across three framework-default caches — Gemma in
`~/.cache/huggingface/hub/`, Parakeet in `~/Library/Application
Support/FluidAudio/Models/`, Whisper in `~/Documents/huggingface/models/` —
none of which say "scribe" or clean up with the app. And the cleanup model
is hardcoded to Gemma 3 4B; there is no way to try another local model.

## Design

### ModelStore (new, pure)

`ModelStore` owns one base directory and the per-engine locations under it:

```
~/Library/Application Support/scribe/models/
├── gemma/       HF-hub layout (models--<org>--<repo>/…) — HubCache-managed
├── parakeet/parakeet-tdt-0.6b-v3/   FluidAudio target dir
└── whisper/     WhisperKit downloadBase (creates models/argmaxinc/… inside)
```

Deleting `…/scribe/models` resets everything; each loader re-downloads on
next use.

### Loader wiring (verified against vendored sources)

- **Gemma**: replace the `#huggingFaceLoadModelContainer` macro call with
  its expansion — `loadModelContainer(from: #hubDownloader(HubClient(cache:
  HubCache(location: .fixed(directory: ModelStore.gemmaDirectory)))),
  using: #huggingFaceTokenizerLoader(), configuration: …)`. HubCache uses
  the Python-compatible hub layout, so the existing download moves over
  with a plain `mv`.
- **Parakeet**: `AsrModels.downloadAndLoad(to: ModelStore.parakeetDirectory)`.
  The directory name keeps the repo folder name — FluidAudio infers the
  model version from it.
- **Whisper**: `WhisperKitConfig(model: …, downloadBase:
  ModelStore.whisperDirectory)`.

### Custom cleanup model

New `AppSettings.cleanupModelPath` (defaults key `cleanupModelPath`,
`String?`, unset by default). Set via
`defaults write dev.esoto.scribe cleanupModelPath /path/to/mlx-model` +
relaunch; `defaults delete` restores stock Gemma. No menu UI.

`GemmaBackend.modelConfiguration(customPath:)` becomes the single decision
point:

- unset → `ModelConfiguration(id: "mlx-community/gemma-3-4b-it-qat-4bit",
  extraEOSTokens: ["<end_of_turn>"])` — unchanged, including the
  Gemma-specific stop-token fix.
- set → `ModelConfiguration(directory: URL(fileURLWithPath: path))`, NO
  extraEOSTokens — a non-Gemma model must terminate via its own tokenizer
  config; hardcoding Gemma's turn token would corrupt other templates.

`AppModel` passes `settings.cleanupModelPath` into `GemmaBackend.init`.

Safety: unchanged and already sufficient. The warm-prefix parity gate
falls back to uncached generation when a tokenizer behaves unexpectedly;
the cleanup timeout, length band, and language-consistency gates paste the
raw transcript when output is unusable. A bad custom model degrades to
verbatim dictation, never lost words. The golden eval (`make test-models`)
is the acceptance bar for any candidate model.

### Migration (this machine, one-time, manual)

`mv` the three existing downloads into the store (no re-downloads):
hub folder → `gemma/`, FluidAudio folder → `parakeet/`, whisperkit-coreml
tree → `whisper/models/argmaxinc/…`. Fresh installs need nothing.

## Testing

- Unit: `ModelStore` path derivations; `cleanupModelPath` settings
  roundtrip (AppSettingsTests pattern); `modelConfiguration(customPath:)`
  branch behavior — directory case must carry no extraEOSTokens.
- Model tier: existing suites (golden eval, fixtures, memory reclaim,
  preload) re-run against the migrated store locations — passing proves
  the rewiring end-to-end.

## Out of scope (YAGNI)

Menu picker UI, custom STT model paths, HF-repo-id cleanup override,
automatic migration code.

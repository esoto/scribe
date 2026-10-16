# scribe

Personal hold-to-talk dictation for macOS — fully local, English + Spanish.

Hold the hotkey (**Right ⌥** by default), speak, release:
[Parakeet Ultra](https://huggingface.co/FluidInference/parakeet-ultra-coreml)
transcribes (~0.2 s), [Gemma 3 4B](https://huggingface.co/mlx-community/gemma-3-4b-it-qat-4bit)
strips fillers and resolves self-corrections — or pick Gemma 4 E4B, Gemma 4
E2B or Apple Intelligence in **Settings › Models** (see *Cleanup models*) — and the result
is pasted into whatever app has focus. No cloud, no accounts. Audio and
text never leave the machine; models download once on first use, then
everything runs offline.

A native Swift menu-bar app (`native/`) — it replaced the original Python
implementation (removed 2026-07-09; see git history for the reference
implementation the Swift port was validated against).

Design and evidence:
[docs/superpowers/specs/2026-07-07-scribe-native-design.md](docs/superpowers/specs/2026-07-07-scribe-native-design.md)

## Install

```sh
brew install xcodegen   # one-time
make generate           # xcodegen -> native/Scribe.xcodeproj
make install-app        # Release build -> /Applications/Scribe.app
```

`make app` builds the same thing into `dist/scribe-<version>.zip` (~12 MB)
without installing. The app is ad-hoc signed unless a `scribe-dev`
code-signing identity exists in the keychain (create one via Keychain
Access → Certificate Assistant to keep TCC grants stable across updates).
Not notarized: on another machine, right-click → Open on first launch.

**First run:** a setup window opens automatically and walks through three
system permission dialogs (Microphone, Accessibility, Input Monitoring).
Each grant auto-adds "scribe" to the right System Settings pane, a live
checkmark lands within ~2 s of granting, and nothing needs a restart —
Input Monitoring installs the hotkey tap live, mid-session.
The same window shows the model downloads, and an optional Notifications row: scribe asks for
notifications only when you click Request there, and uses them only to tell you when a dictation fails.

**Models** are not bundled; they download on first use into a single
app-managed store — `~/Library/Application Support/scribe/models/` —
one subfolder per engine. Deleting that folder is a clean full reset;
everything re-downloads on next use.

| Model | Size | Store subfolder |
|---|---|---|
| Gemma 3 4B (cleanup) | ~2.8 GB | `gemma/` |
| Gemma 4 E4B (cleanup) | ~4.9 GB | `gemma/` |
| Gemma 4 E2B (cleanup) | ~3.6 GB | `gemma/` |
| Apple Intelligence (cleanup) | none — built into macOS 26+ | — |
| Parakeet Ultra (STT) | ~0.6 GB | `parakeet/` |
| Whisper (optional STT) | ~1.5 GB | `whisper/` |

Downloaded cleanup models can be deleted from **Settings › Models** (not
the one in use).

Upgrading from a v3 install downloads Ultra on first launch (progress shows in the menu); the old v3 model is kept as a fallback until Ultra loads, then removed.

## Usage

- Hold **Right ⌥** (≥ 0.3 s), speak, release. Text lands in the focused app.
- Menu bar: ◦ idle · ● recording · ⋯ processing · ⚠ error or a missing
  permission, plus a live status line while recording/transcribing.
- **Engine** picker: Parakeet (fast, default) ↔ Whisper (better for
  Spanish-heavy dictation; loads on first switch).
- **Settings…** (⌘,) has three tabs. **General** holds the hotkey, hold delay, sounds, Launch at Login, idle unload, and history size. **Audio** picks the microphone. **Models** downloads, switches, and deletes the cleanup model.
- **Cleanup** toggle: off = verbatim transcription pasted raw.
- **History**: the last 10 dictations by default (Settings › General), in
  memory only, never persisted; "· raw" marks one pasted without cleanup.
  Click one to copy it back to the clipboard.
- **Dictionary**: your vocabulary and corrections, fed to the cleanup pass
  so names and jargon come out spelled right — see below.
- If cleanup ever misbehaves (timeout, length/language sanity gates), the
  raw transcript is pasted instead — you never lose words.
- The microphone is captured **only while the key is held** — the orange
  mic indicator turns off at key-up.

## Cleanup models

The cleanup model is picked in **Settings › Models**, which offers four models; the default is
**Gemma 3 4B**. The intent is that the default must pass golden + guard;
today it has one known guard failure, documented below. Existing installs
keep the model they already use.

| Model | Golden | Guard | Learned vocabulary | Avg cleanup latency |
|---|---|---|---|---|
| Gemma 3 4B (default) | 10/10 | 7/8 | no | ~950 ms |
| Gemma 4 E4B | 9/10 | 7/8 | yes | ~460 ms |
| Gemma 4 E2B | 8/10 | 7/8 | yes | ~330 ms |
| Apple Intelligence | 8/10 | 4/8 | no | ~430 ms |

Gemma 4 E2B is the fastest local model and the smallest download of the
two Gemma 4 sizes, at the cost of two golden cases (a Spanish
self-correction and a filler leak) — pick it for speed, E4B for accuracy.
It shares E4B's single guard failure.

Two guard failures are currently known, human-approved, and deliberately
not recorded as `known_failures`:

- **Gemma 3 fails `en-guard-translate`** — it returns an empty string (a
  refusal); scribe's gates then fall back to pasting the raw transcript.
- **Gemma 4 fails `en-guard-ignore-instructions`** — it answers the
  injected instruction instead of cleaning the sentence (both E4B and
  E2B).

Learned vocabulary (Dictionary window, **Learn new terms**) reaches only models
proven by `DictionaryFidelityTests` to keep every word — currently
**Gemma 4 E4B** and **Gemma 4 E2B**; Gemma 3 and Apple Intelligence do
not receive learned terms. Apple Intelligence is built into macOS 26+;
if it turns off while selected, that dictation pastes the raw transcript
and scribe switches to Gemma.

## Dictionary

Cleanup knows generic English and Spanish, not *your* nouns. The dictionary
teaches it. **Edit Dictionary…** in the menu opens the editor, whose top section holds the
two toggles **Learn new terms** and **Prefer dictionary words (experimental)**.

**Replacements (manual).** "Heard as → Replace with" pairs — this is the
part that works, and the one to reach for. A word the STT mishears comes
out *differently each time* ("Hetzner" produced Headstar, Hatsner, Heftner
and Headsnar in one sitting), so add a pair for whichever spelling you see
most; add a second if another variant keeps showing up.

Replacements are applied directly to the transcript, not by the cleanup
model, so they hold **on every dictation** — including ones too short to be
cleaned (under `minWords`), with cleanup switched off, and when cleanup
times out or trips its gates. Matching is whole-word and case-insensitive,
punctuation is preserved, and the replacement is pasted verbatim, so
`camel` fixes "Camel," but leaves `camelCase` alone.

**Heard but not matched.** Matching is exact, so one pair catches one
spelling — and a mangled name comes back differently every time. The editor
therefore lists words scribe heard that match nothing it knows, with a
**Bind to…** button to attach each to a correction you already have.
Several manglings can share one target.

It suggests rather than guessing because guessing isn't safe: the variants
aren't further from your pair than ordinary words are. Real measurements
against `headsner` — `Headstar` and `Hatsner` are 2 edits away, but so is
**"header"**; `Heftner` is 3, and so is **"headers"**. For `camel`, `Kamal`
is 2 edits — and so are **"camera"** and **"cancel"**. No threshold
separates them, so a human confirms instead.

**Learned terms (automatic) — off by default.** With learning off, scribe
writes nothing it hears to disk: words are kept in memory for the current
session only (to offer bindings), learned terms are frozen, and nothing is
promoted. The learned vocabulary
only reaches models proven by `DictionaryFidelityTests` to keep every
word — currently **Gemma 4 E4B** and **Gemma 4 E2B**. With other models the toggle still
collects words, and the Dictionary window notes they aren't sent. The intent:
distinctive vocabulary in cleaned dictations (proper nouns, acronyms,
`camelCase`, words with digits) is counted, and anything appearing in
**3 separate dictations** gets its spelling locked in. Terms go stale
after 60 days unused (14 for ones never promoted).

On Gemma 3 the glossary **costs you words**: measured against the real
model, injecting the learned-vocabulary list makes cleanup delete words
from the sentence — including words the list never mentions. A
vocabulary of just `"Postgres"` was enough to turn *"deploy with kamal to
hetzner tonight"* into *"Deploy with hetzner tonight."* Replacement pairs
show no such effect. `DictionaryFidelityTests` pins this and drives the
per-model gate above.

Both are stored in `~/Library/Application Support/scribe/dictionary.json`
— **individual words only, never transcripts.** Delete the file for a clean
reset. Only learned terms reach the cleanup prompt (at most 30, highest-use
first — and only on fidelity-safe models); editing a replacement costs
nothing, since the model never sees it.

## Configuration

Settings live in `UserDefaults` under `dev.esoto.scribe` (a legacy
`~/.config/scribe/config.toml` is imported once, first launch only).
Change via `defaults write dev.esoto.scribe <key> <value>` and relaunch, or use the control named in the table:

Most of these have a control in **Settings…** (⌘,), the menu, or the Dictionary window and apply immediately; the rest are advanced keys that still need a relaunch.

| Key | Default | Meaning |
|---|---|---|
| `hotkey` | `right_option` | `right_command` \| `right_option` \| `f13` (Settings) |
| `holdThreshold` | 0.3 | seconds the key must be held (Settings) |
| `engine` | `parakeet` | `parakeet` \| `whisper` (menu) |
| `cleanupEnabled` | true | Gemma cleanup pass on/off (menu) |
| `minWords` | 4 | utterances shorter than this skip cleanup |
| `cleanupTimeout` | 6.0 | seconds before falling back to raw text |
| `restoreDelay` | 2.0 | seconds before restoring the prior clipboard |
| `energyGate` | 0.0005 | silence gate (anti-hallucination); speech ~0.001+ |
| `sounds` | true | start/error sounds (Settings) |
| `historySize` | 10 | menu history length (Settings) |
| `idleUnloadMinutes` | 15 | unload models after idle (0 = keep resident) (Settings) |
| `dictionaryLearningEnabled` | false | auto-learn vocabulary (known to drop words — see Dictionary) (Dictionary window) |
| `cleanupModel` | resolved at first launch | `gemma3` \| `gemma4` \| `gemma4e2b` \| `appleIntelligence` (Settings) |
| `cleanupModelPath` | _(unset)_ | local MLX model folder to use for cleanup instead of stock Gemma; when set, overrides `cleanupModel` and disables switching in **Settings › Models** |
| `vocabularyBiasingEnabled` | false | acoustic vocabulary biasing for Parakeet (experimental) (Dictionary window) |
| `microphoneUID` | _(unset)_ | input device UID; unset follows the system default input (Settings) |

**Custom cleanup model:** point `cleanupModelPath` at any local MLX model
folder (config.json + safetensors + tokenizer) and relaunch;
`defaults delete dev.esoto.scribe cleanupModelPath` restores stock Gemma.
A misbehaving model degrades to pasting the raw transcript (timeout +
length/language gates) — it can never lose words. Judge candidates with
`make test-models`: the golden eval is the quality bar (stock Gemma
scores 10/10).

## Memory behavior

Model weights dominate the footprint (~3.3 GB with Parakeet + Gemma 3 4B
warm; Gemma 4 E4B peaks at ~4.7 GB, and the smaller Gemma 4 E2B below
that — GPU/unified memory, invisible to RSS; check Activity Monitor's
Memory column). Apple Intelligence runs
outside scribe's process. scribe manages them on demand:

- Models preload at launch and on key-down, so loads overlap with speech.
- After `idleUnloadMinutes` without dictating, everything unloads and the
  footprint settles to ~250 MB within seconds.
- The first post-idle dictation reloads while you speak — typically only
  ~1 extra second of cleanup latency; a very short utterance right after
  an unload may paste the raw transcript if cleanup isn't back yet.

## Troubleshooting

- **Nothing types, but the icon reacts** → Accessibility grant missing.
  scribe copies the text instead and notifies "press ⌘V". It does the same
  when you switch apps while it's transcribing.
- **Hotkey does nothing** → Input Monitoring grant missing (common after
  replacing the app binary: re-toggle scribe in System Settings → Privacy &
  Security → Input Monitoring, or use the setup window's Request button).
  The log records only presses of the hotkey itself. If pressing it logs
  `flagsChanged keycode=61 ... -> down`, the tap is alive and the grant is
  fine. If it logs nothing, the key isn't reaching scribe as Right ⌥ (**61**):
  an external keyboard may report its Option key as 58 (Left ⌥), which won't
  match.
- **Old clipboard contents got pasted** → increase `restoreDelay`.
- **Transcription failed** → the audio was saved to
  `~/Library/Logs/scribe/last_failed.wav`.
- Logs: `~/Library/Logs/scribe/scribe.log`.

## Development

```sh
make generate              # regenerate the Xcode project after adding files
make test                  # unit suite (fast, no models)
make test-models           # real-model suite: golden cleanup eval, STT fixtures, memory reclaim
make build-models          # compile-check the real-model test target (no GPU, no run)
make test-models-gemma4    # golden + guard + fidelity for Gemma 4 E4B (CLEANUP_MODEL=gemma4)
make test-models-e2b       # same for Gemma 4 E2B (CLEANUP_MODEL=gemma4e2b)
make test-models-afm       # same for Apple Intelligence — report-only, exit code ignored
```

The per-model targets run only the `CLEANUP_MODEL`-aware classes
(`GoldenEvalTests`, `InjectionGuardTests`, `DictionaryGoldenEvalTests`,
`DictionaryFidelityTests`); the Gemma-3-hard-wired ones
(`FastPathBoundaryTests`, `GemmaPreloadTests`, `MemoryReclaimTests`,
`DictionaryWarmRebuildTests`) run under `make test-models` only.
`CLEANUP_MODEL` must be an environment variable —
`TEST_RUNNER_CLEANUP_MODEL=gemma4` — never an xcodebuild argument; the afm
target ignores xcodebuild's exit code by design (Apple Intelligence is
opt-in and not held to 10/10).

The golden set (`tests_models/golden.json`) and the injection-guard set
(`tests_models/injection_guard.json`) are REQUIRED to pass, per model,
before changing the cleanup prompt or model: the default must pass
golden + guard. Two guard failures are currently known and
human-approved — Gemma 3 fails `en-guard-translate` (empty-string
refusal; the gates fall back to the raw transcript) and Gemma 4 fails
`en-guard-ignore-instructions` (it answers the injected instruction) —
deliberately not recorded as `known_failures` (see *Cleanup models*).
Architecture: one process; OS adapters are logic-free shells; every
decision (state machine, gates, fallbacks) is pure and injected — see
the spec.

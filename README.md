# scribe

Personal hold-to-talk dictation for macOS — fully local, English + Spanish.

Hold the hotkey (**Right ⌥** by default), speak, release:
[Parakeet TDT v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)
transcribes (~0.2 s), [Gemma 3 4B](https://huggingface.co/mlx-community/gemma-3-4b-it-qat-4bit)
strips fillers and resolves self-corrections, and the result is pasted into
whatever app has focus. No cloud, no accounts. Audio and text never leave
the machine; models download once on first use, then everything runs
offline.

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

**Models** are not bundled; they download on first use into a single
app-managed store — `~/Library/Application Support/scribe/models/` —
one subfolder per engine. Deleting that folder is a clean full reset;
everything re-downloads on next use.

| Model | Size | Store subfolder |
|---|---|---|
| Gemma 3 4B (cleanup) | ~2.8 GB | `gemma/` |
| Parakeet v3 (STT) | ~0.5 GB | `parakeet/` |
| Whisper (optional STT) | ~1.5 GB | `whisper/` |

## Usage

- Hold **Right ⌥** (≥ 0.3 s), speak, release. Text lands in the focused app.
- Menu bar: ◦ idle · ● recording · ⋯ processing · ⚠ error, plus a live
  status line while recording/transcribing.
- **Engine** picker: Parakeet (fast, default) ↔ Whisper (better for
  Spanish-heavy dictation; loads on first switch).
- **Cleanup** toggle: off = verbatim transcription pasted raw.
- **History**: last 10 dictations (in memory only, never persisted); click
  one to copy it back to the clipboard.
- **Dictionary**: your vocabulary and corrections, fed to the cleanup pass
  so names and jargon come out spelled right — see below.
- If cleanup ever misbehaves (timeout, length/language sanity gates), the
  raw transcript is pasted instead — you never lose words.
- The microphone is captured **only while the key is held** — the orange
  mic indicator turns off at key-up.

## Dictionary

Cleanup knows generic English and Spanish, not *your* nouns. The dictionary
teaches it — menu bar → **Dictionary**, or **Edit Dictionary…** for the
full editor.

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

**Learned terms (automatic) — off by default, and it should stay off for
now.** The intent: distinctive vocabulary in cleaned dictations (proper
nouns, acronyms, `camelCase`, words with digits) is counted, and anything
appearing in **3 separate dictations** gets its spelling locked in. Terms
go stale after 60 days unused (14 for ones never promoted).

It's disabled because it currently **costs you words.** Measured against
the real model, injecting the learned-vocabulary list makes cleanup delete
words from the sentence — including words the list never mentions. A
vocabulary of just `"Postgres"` was enough to turn *"deploy with kamal to
hetzner tonight"* into *"Deploy with hetzner tonight."* Replacement pairs
show no such effect. `DictionaryFidelityTests` pins this; **Learn New
Terms** enables it anyway if you want to experiment.

Both are stored in `~/Library/Application Support/scribe/dictionary.json`
— **individual words only, never transcripts.** Delete the file for a clean
reset. Only learned terms reach the cleanup prompt (at most 30, highest-use
first); editing a replacement costs nothing, since the model never sees it.

## Configuration

Settings live in `UserDefaults` under `dev.esoto.scribe` (a legacy
`~/.config/scribe/config.toml` is imported once, first launch only).
Change via `defaults write dev.esoto.scribe <key> <value>` and relaunch:

| Key | Default | Meaning |
|---|---|---|
| `hotkey` | `right_option` | `right_command` \| `right_option` \| `f13` |
| `holdThreshold` | 0.3 | seconds the key must be held |
| `engine` | `parakeet` | `parakeet` \| `whisper` |
| `cleanupEnabled` | true | Gemma cleanup pass on/off |
| `minWords` | 4 | utterances shorter than this skip cleanup |
| `cleanupTimeout` | 6.0 | seconds before falling back to raw text |
| `restoreDelay` | 2.0 | seconds before restoring the prior clipboard |
| `energyGate` | 0.0005 | silence gate (anti-hallucination); speech ~0.001+ |
| `sounds` | true | start/error sounds |
| `historySize` | 10 | menu history length |
| `idleUnloadMinutes` | 15 | unload models after idle (0 = keep resident) |
| `dictionaryLearningEnabled` | false | auto-learn vocabulary (known to drop words — see Dictionary) |
| `cleanupModelPath` | _(unset)_ | local MLX model folder to use for cleanup instead of stock Gemma |

**Custom cleanup model:** point `cleanupModelPath` at any local MLX model
folder (config.json + safetensors + tokenizer) and relaunch;
`defaults delete dev.esoto.scribe cleanupModelPath` restores stock Gemma.
A misbehaving model degrades to pasting the raw transcript (timeout +
length/language gates) — it can never lose words. Judge candidates with
`make test-models`: the golden eval is the quality bar (stock Gemma
scores 10/10).

## Memory behavior

Model weights dominate the footprint (~3.3 GB with Parakeet + Gemma warm —
GPU/unified memory, invisible to RSS; check Activity Monitor's Memory
column). scribe manages them on demand:

- Models preload at launch and on key-down, so loads overlap with speech.
- After `idleUnloadMinutes` without dictating, everything unloads and the
  footprint settles to ~250 MB within seconds.
- The first post-idle dictation reloads while you speak — typically only
  ~1 extra second of cleanup latency; a very short utterance right after
  an unload may paste the raw transcript if cleanup isn't back yet.

## Troubleshooting

- **Nothing types, but the icon reacts** → Accessibility grant missing.
- **Hotkey does nothing** → Input Monitoring grant missing (common after
  replacing the app binary: re-toggle scribe in System Settings → Privacy &
  Security → Input Monitoring, or use the setup window's Request button).
  If the log shows `flagsChanged` lines while you type, the tap is alive and
  the grant is fine — check the keycode: Right ⌥ is **61**, and an external
  keyboard may report its Option key as 58 (Left ⌥), which won't match. A
  press that registers logs `keycode=61 ... -> down`.
- **Old clipboard contents got pasted** → increase `restoreDelay`.
- **Transcription failed** → the audio was saved to
  `~/Library/Logs/scribe/last_failed.wav`.
- Logs: `~/Library/Logs/scribe/scribe.log`.

## Development

```sh
make generate     # regenerate the Xcode project after adding files
make test         # unit suite (fast, no models)
make test-models  # real-model suite: golden cleanup eval, STT fixtures, memory reclaim
```

The golden set (`tests_models/golden.json`) is REQUIRED to pass before
changing the cleanup prompt or model. Architecture: one process; OS
adapters are logic-free shells; every decision (state machine, gates,
fallbacks) is pure and injected — see the spec.

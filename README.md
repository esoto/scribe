# scribe

Personal hold-to-talk dictation for macOS — fully local, English + Spanish.

Hold **Right ⌘**, speak, release: [Parakeet TDT v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)
transcribes (~0.2 s), [Gemma 3 4B](https://huggingface.co/mlx-community/gemma-3-4b-it-qat-4bit)
strips fillers and resolves self-corrections, and the result is pasted into
whatever app has focus. No cloud, no accounts. ~3.5 GB resident RAM on Apple Silicon.

**Privacy:** audio and text never leave the machine. The app sets
`HF_HUB_OFFLINE=1` at startup, so after the one-time model downloads it makes
zero network requests — not even Hugging Face's are-you-up-to-date check.
To download a new model (e.g. after changing a model repo in the config),
run once with `HF_HUB_OFFLINE=0 make run`.

Design and evidence: [docs/superpowers/specs/2026-07-06-scribe-dictation-app-design.md](docs/superpowers/specs/2026-07-06-scribe-dictation-app-design.md)

## Native app (scribe.app)

A Swift rewrite (`native/`) is replacing the Python app below. It runs as a
real `.app` bundle with its own TCC identity — System Settings shows
**"scribe"** with an icon in Microphone / Accessibility / Input Monitoring,
not a hidden `Python.app` inside a Homebrew framework, and grants survive
`.venv` rebuilds because there's no `.venv`. Same product behavior: Parakeet
v3 → Gemma 3 4B cleanup → paste, same gates, same cleanup prompt, same
golden eval as the parity oracle.

Design: [docs/superpowers/specs/2026-07-07-scribe-native-design.md](docs/superpowers/specs/2026-07-07-scribe-native-design.md)

**Build:**

```sh
brew install xcodegen   # if not already installed
cd native
xcodegen generate
xcodebuild -project Scribe.xcodeproj -scheme Scribe \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation build
```

The built `.app` lands under DerivedData, not in `native/`. Find it with:

```sh
xcodebuild -project Scribe.xcodeproj -scheme Scribe -showBuildSettings \
  | grep BUILT_PRODUCTS_DIR
```

— or skip the CLI entirely and open `native/Scribe.xcodeproj` in Xcode, ⌘R.

**First run:** a setup window opens automatically and walks through three
system permission dialogs (Microphone, Accessibility, Input Monitoring).
Each grant auto-adds "scribe" to the right System Settings pane, a live
checkmark lands within ~2 s of granting, and nothing needs a restart —
Input Monitoring installs the hotkey tap live, mid-session.

**Dev hotkey:** the native app defaults to **Right ⌥**, not Right ⌘, so it
can run side by side with the Python app below during validation without
double-pasting. See `docs/pending-validation.md` for the cutover checklist
and the switch to Right ⌘.

---

Everything from here down describes the Python app — *(reference
implementation — the native app is replacing it; Python stays as oracle +
eval harness)*.

## Install

```sh
make venv          # creates .venv and installs dependencies
make test          # unit suite (no models needed)
make test-models   # integration suite — downloads/loads the MLX models
make run           # run in the foreground (first run: see Permissions)
make install-agent # start at login via launchd
```

## Permissions (one-time, and after any .venv rebuild)

scribe needs three grants. **Run `make doctor` first — it prints the exact
path macOS attributes the grants to.** (Gotcha: framework Python re-execs
into a hidden `Python.app` bundle inside the Homebrew framework; grants on
`.venv/bin/python` or `bin/python3.14` target the wrong binary and silently
do nothing. `ps` shows the truth; `sys.executable` does not.)

1. **Microphone** — prompted automatically on first recording.
2. **Accessibility** — System Settings → Privacy & Security → Accessibility → “+” → ⌘⇧G → paste the path from `make doctor`. Needed to send ⌘V.
3. **Input Monitoring** — same pane group → Input Monitoring → same path. Needed for the hold-to-talk key.

Restart scribe after granting. **Rebuilding `.venv` or upgrading Homebrew
Python invalidates the grants** — re-run `make doctor` and re-add.

## Usage

- Hold Right ⌘ (≥ 0.3 s), speak, release. Text lands in the focused app.
- Menu bar: ◦ idle · ● recording · ⋯ processing · ⚠ error.
- **Engine** menu: Parakeet (fast, default) ↔ Whisper (better for Spanish-heavy dictation; loads on first switch, ~1 s per utterance).
- **Cleanup** toggle: off = verbatim transcription pasted raw.
- **History**: last 10 dictations; click one to copy it back to the clipboard.
- If cleanup ever misbehaves, the raw transcript is pasted instead — you never lose words.

## Configuration

`~/.config/scribe/config.toml` (all keys optional; defaults shown):

```toml
[hotkey]
key = "right_command"        # right_command | right_option | f13
hold_threshold_s = 0.3

[stt]
engine = "parakeet"          # parakeet | whisper

[cleanup]
enabled = true
min_words = 4                # utterances shorter than this skip cleanup
timeout_s = 6.0
length_band = [0.5, 1.3]     # cleaned/raw length ratio sanity band

[paste]
clipboard_restore_delay_s = 2.0

[audio]
energy_gate_rms = 0.0005     # silence gate (primary anti-hallucination defense); real speech ~0.001+, digital silence ~0.0001

[ui]
sounds = true
history_size = 10

[memory]
idle_unload_minutes = 15     # unload models after this many idle minutes (~5 GB reclaimed); 0 = keep resident
```

## Memory behavior

Model weights dominate the footprint (~1.3 GB Parakeet, ~2.5 GB Gemma,
~1.6 GB Whisper — all in GPU/unified memory, invisible to RSS; use
`footprint <pid>` to see the truth). scribe manages them on demand:

- Only the **active** STT engine holds weights; switching engines frees the
  other one.
- After `idle_unload_minutes` without dictating, everything unloads
  (footprint → ~300 MB). The next hotkey press starts reloading while you
  speak; the first post-idle dictation takes a few extra seconds and may
  paste the raw (uncleaned) transcript if the cleanup model isn't back yet.

## Troubleshooting

- **Nothing types, but the icon reacts** → Accessibility grant missing (`make doctor`).
- **Hotkey does nothing** → Input Monitoring grant missing, or the app that has focus is capturing the key.
- **Old clipboard contents got pasted** → increase `clipboard_restore_delay_s`.
- **First words clipped** → shouldn't happen (stream is pre-opened); check `~/.local/state/scribe/scribe.log`.
- **Transcription failed** → the audio was saved to `~/.local/state/scribe/last_failed.wav`.
- Logs: `~/.local/state/scribe/scribe.log` (7-day rotation).

## Development

```sh
make cov     # unit tests + coverage (pure logic ~100%, gate at 95%)
make eval    # cleanup-prompt golden set — REQUIRED before changing the prompt or model
```

Architecture: one process; OS adapters are logic-free shells; every decision
(state machine, gates, fallbacks) is pure and injected — see the spec.

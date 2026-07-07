# scribe

Personal hold-to-talk dictation for macOS — fully local, English + Spanish.

Hold **Right ⌘**, speak, release: [Parakeet TDT v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)
transcribes (~0.2 s), [Gemma 3 4B](https://huggingface.co/mlx-community/gemma-3-4b-it-qat-4bit)
strips fillers and resolves self-corrections, and the result is pasted into
whatever app has focus. No cloud, no accounts. ~3.5 GB resident RAM on Apple Silicon.

Design and evidence: [docs/superpowers/specs/2026-07-06-scribe-dictation-app-design.md](docs/superpowers/specs/2026-07-06-scribe-dictation-app-design.md)

## Install

```sh
make venv          # creates .venv and installs dependencies
make test          # unit suite (no models needed)
make test-models   # integration suite — downloads/loads the MLX models
make run           # run in the foreground (first run: see Permissions)
make install-agent # start at login via launchd
```

## Permissions (one-time, and after any .venv rebuild)

macOS ties privacy grants to the exact interpreter binary (`.venv/bin/python`).
scribe needs three:

1. **Microphone** — prompted automatically on first recording.
2. **Accessibility** — System Settings → Privacy & Security → Accessibility → add `.venv/bin/python`. Needed to send ⌘V.
3. **Input Monitoring** — System Settings → Privacy & Security → Input Monitoring → add `.venv/bin/python`. Needed for the hold-to-talk key.

Run `make doctor` any time to see exactly what's missing. **Rebuilding
`.venv` invalidates all three grants** — you'll need to re-add the binary.

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
energy_gate_rms = 0.005      # silence gate (primary anti-hallucination defense)

[ui]
sounds = true
history_size = 10
```

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

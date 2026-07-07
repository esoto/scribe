# Pending validation — what needs a human

Status as of 2026-07-07. Everything automatable was automated and passes:
unit suite 66/66 (99.7% coverage on pure logic), model integration suite
10/10, cleanup eval 10/10, `make doctor` functional, all modules import.
What remains requires your voice, your screen, or your click.

## 1. One-time setup (blocking — the app is inert without these)

macOS TCC grants bind to `.venv/bin/python`. `make doctor` currently reports
all three missing (expected — this binary has never asked):

1. **Input Monitoring** — System Settings → Privacy & Security → Input
   Monitoring → “+” → add `~/development/susurro/.venv/bin/python`.
   Without it the hold-to-talk key is invisible to the app.
2. **Accessibility** — same pane group → Accessibility → add the same binary.
   Without it ⌘V cannot be synthesized (text stays on the clipboard).
3. **Microphone** — will be prompted automatically the first time you hold
   the hotkey. Run `make run` from *your* terminal (not an agent session) so
   the prompt attributes correctly.

Then: `make run` (foreground, watch it work) → `make install-agent` (login).
Re-run `make doctor` after granting; all four lines should be ✓.
**Any `.venv` rebuild silently invalidates all three grants.**

## 2. Spec §9 checklist — real-voice validation (~15 min)

The engine benchmarks used synthesized TTS voices; these need your real
voice, accent, and mic:

- [ ] 5 Spanish dictations through Parakeet (default). If accuracy annoys,
      switch default: `engine = "whisper"` in `~/.config/susurro/config.toml` —
      Whisper measured better on Spanish (3.12% vs 4.39% WER, FLEURS).
- [ ] 5 English + 5 mixed EN/ES dictations — confirm cleanup never eats content
      (if it does, the raw text is in History; report the case so it joins the
      golden set).
- [ ] One day of daily-driver use: paste reliability in Ghostty/terminal,
      browser, Slack. If stale clipboard ever pastes, raise
      `clipboard_restore_delay_s`.
- [ ] Sleep/wake and AirPods connect/disconnect while running (recorder should
      reopen on next key-down; watch `~/.local/state/susurro/susurro.log`).
- [ ] RAM under pressure: susurro (~3.5 GB) + Xcode + Rails simultaneously.

## 3. Findings from implementation (already handled, documented for the record)

| Finding | Evidence | Resolution |
|---|---|---|
| mlx-whisper hallucinated "Thank you." on near-silence with `no_speech_prob=0.0` | probe 2026-07-07 | Energy gate is the primary defense (silence never reaches an engine); `condition_on_previous_text=False` always set |
| transformers 5.13 breaks mlx-lm 0.31.3 Gemma-3 loading (`AttributeError` in auto_factory) | fresh venv install | Pinned `transformers>=5.5,<5.6` |
| Gemma 3 4B translated short EN inputs to ES (and Spanglish ES to EN) | eval golden set | Same-language rule + multi-turn few-shot in prompt; runtime `language_consistent` gate → raw pasted on any flip |
| Inline few-shot examples in the system prompt made Gemma parrot the last example verbatim | eval | Few-shots moved to chat-format user/assistant pairs |
| Gemma preserves request-looking text nearly verbatim (won't resolve "ocean um actually mountains") | eval case `en-request-not-fulfilled` | **Accepted**: preserve-over-edit is the safe failure mode vs. executing the request. Golden asserts non-execution only |
| "o sea" survives cleanup when used as a connector ("that is") | eval | Accepted as linguistically correct; goldens only require hard fillers (um/uh/este/eh) gone |

## 4. Open experiments (non-blocking, when you feel like it)

- **apple-fm-sdk cleanup backend A/B** — official Python bindings for Apple's
  on-device model (zero RAM). Blocked on quality today (failed 3/3 probes
  2026-07-06); revisit when macOS 27 gen-3 models land. The `CleanupBackend`
  interface + `make eval` make this a ~50-line experiment.
- **F13 / foot-pedal hotkey** — already supported via `key = "f13"`, untested
  on real hardware.
- **Signed .app wrapper (py2app)** — kills the TCC-rebind-on-venv-rebuild
  annoyance if it ever gets old.
- **launchd agent behavior after reboot** — `make install-agent` written per
  launchctl docs but not yet exercised through a real login cycle.

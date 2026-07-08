# Pending validation — what needs a human

Status as of 2026-07-07. Everything automatable was automated and passes:
unit suite 66/66 (99.7% coverage on pure logic), model integration suite
10/10, cleanup eval 10/10, `make doctor` functional, all modules import.
What remains requires your voice, your screen, or your click.

> **Update 2026-07-07 ~12:30:** Section 1 is DONE — all grants verified live
> (mic 3/authorized, input monitoring tap enabled, post-event access True)
> and the first real dictations completed end-to-end. Section 2 (real-voice
> quality checklist) is what remains.

## 1. One-time setup (blocking — the app is inert without these) — ✅ COMPLETED

macOS TCC grants bind to `.venv/bin/python`. `make doctor` currently reports
all three missing (expected — this binary has never asked):

1. **Input Monitoring** — System Settings → Privacy & Security → Input
   Monitoring → “+” → add `~/development/scribe/.venv/bin/python`.
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
      switch default: `engine = "whisper"` in `~/.config/scribe/config.toml` —
      Whisper measured better on Spanish (3.12% vs 4.39% WER, FLEURS).
- [ ] 5 English + 5 mixed EN/ES dictations — confirm cleanup never eats content
      (if it does, the raw text is in History; report the case so it joins the
      golden set).
- [ ] One day of daily-driver use: paste reliability in Ghostty/terminal,
      browser, Slack. If stale clipboard ever pastes, raise
      `clipboard_restore_delay_s`.
- [ ] Sleep/wake and AirPods connect/disconnect while running (recorder should
      reopen on next key-down; watch `~/.local/state/scribe/scribe.log`).
- [ ] RAM under pressure: scribe (~3.5 GB) + Xcode + Rails simultaneously.

## 3. Findings from implementation (already handled, documented for the record)

| Finding | Evidence | Resolution |
|---|---|---|
| mlx-whisper hallucinated "Thank you." on near-silence with `no_speech_prob=0.0` | probe 2026-07-07 | Energy gate is the primary defense (silence never reaches an engine); `condition_on_previous_text=False` always set |
| transformers 5.13 breaks mlx-lm 0.31.3 Gemma-3 loading (`AttributeError` in auto_factory) | fresh venv install | Pinned `transformers>=5.5,<5.6` |
| Gemma 3 4B translated short EN inputs to ES (and Spanglish ES to EN) | eval golden set | Same-language rule + multi-turn few-shot in prompt; runtime `language_consistent` gate → raw pasted on any flip |
| Inline few-shot examples in the system prompt made Gemma parrot the last example verbatim | eval | Few-shots moved to chat-format user/assistant pairs |
| Gemma preserves request-looking text nearly verbatim (won't resolve "ocean um actually mountains") | eval case `en-request-not-fulfilled` | **Accepted**: preserve-over-edit is the safe failure mode vs. executing the request. Golden asserts non-execution only |
| "o sea" survives cleanup when used as a connector ("that is") | eval | Accepted as linguistically correct; goldens only require hard fillers (um/uh/este/eh) gone |

## 3b. Findings from first-run debugging (2026-07-07, app confirmed working end-to-end)

| Finding | Evidence | Resolution |
|---|---|---|
| TCC grants on `.venv/bin/python` / `bin/python3.14` do nothing — framework Python re-execs into a hidden `Python.app` bundle | `ps` showed `…/Resources/Python.app/Contents/MacOS/Python`; `sys.executable` lies | `make doctor` prints the real grant target; grants live on Python.app |
| Terminal-launched processes attribute TCC to the TERMINAL (responsible process), not to Python | probe from iTerm: all grants False while Settings showed Python ✓ | Run via launchd (`make install-agent`) where Python.app is its own identity; probe prints the caveat |
| macOS 26 creates listen-only event taps WITHOUT the Input Monitoring grant, then silently leaves them disabled | probe: `tap created: True, tap enabled: False`; app never errored | App now checks `CGEventTapIsEnabled` after enabling and raises loudly |
| ObjC blocks must return void — returning any value from a PyObjC main-queue block aborts the app | Doctor-click crash: `OC_PythonException … expecting void return value` | All UI blocks wrapped in `_on_main` (logs exceptions, never propagates) |
| rumps `MenuItem.clear()` crashes on a never-populated submenu | first-dictation crash: `'NoneType' … removeAllItems` | History submenu seeded with "(empty)" at construction |
| Energy gate 0.005 (calibrated on loud TTS fixtures) discarded ALL real dictation — real speech on the built-in mic is rms 0.001–0.002 | six discards logged with healthy rms | Default gate lowered to 0.0005 (2× below quiet speech, 3.5× above digital silence) |
| **MLX weights bind to the loading thread's GPU stream; any other thread gets "There is no Stream(gpu, N) in current thread"** | reproduced in 5 isolated experiments | `MlxThread` owns all loads + inference; `ThreadBound*` wrappers marshal calls; cross-thread regression test in tier-2 |
| `CGEventPost` without Accessibility is SILENTLY swallowed — no error, no paste | "dictation ok" logged but no text visible | Startup logs + requests post-event access (`CGPreflightPostEventAccess`) |

## Native app (scribe-native) — cutover checklist

Branch `claude/scribe-native`. Status: **built** (`xcodebuild build` clean,
no warnings), **96/96 unit tests green**, **model suite 8/8**, **golden eval
parity 10/10** (matches the Python oracle byte-for-byte on chat-template
structure — see `native/SPIKE-RESULTS.md` "Task 15 parity run"). All
automated reviews clean. What's left is the same category as the Python
app's own §2 above: real voice, your screen, your click.

### Manual QA still pending (from Task 14 handoff)

The native onboarding + hotkey adapters were built and unit-tested but never
exercised through a real launch. Confirm on first real run:

- [ ] **Real TCC prompt flow on first launch** — this Mac's grants are bound
      to the Python `scribe` process, not the native bundle (`dev.esoto.scribe`),
      so the native app should show all three permissions ✗ and trigger the
      actual OS dialogs (Microphone, Accessibility, Input Monitoring) — not
      just the unit-tested `OnboardingState` logic.
- [ ] **Auto-open at launch** — the onboarding window should open itself
      when grants are missing at true app launch, without the user clicking
      the menu bar icon first (`MenuBarLabel.onAppear`, unobserved live as of
      Task 14).
- [ ] **Live hotkey activation after granting Input Monitoring** — granting
      mid-session should install the hotkey tap without an app restart; the
      row's own checkmark lags up to ~2 s behind the grant (poll cadence, by
      design, not a bug).
- [ ] **Window-close poll cancellation** — closing the onboarding window
      before all grants land should stop the 2 s poll loop cleanly (no
      leaked timer/task).

### Cutover steps (spec §8)

1. **Side-by-side validation on Right ⌥** — the native app already defaults
   to Right ⌥ (`AppSettings.hotkey`) specifically so it can run alongside the
   Python app (Right ⌘) without double-pasting. Run both.
2. **Rule-of-five human check** — 5 English + 5 Spanish real dictations
   through *both* apps, outputs compared. This is the one gate no automated
   suite can clear; golden eval parity (10/10) covers the cleanup model in
   isolation, not the full mic → STT → cleanup → paste pipeline on real
   speech.
3. **Retire the Python agent** — `make uninstall-agent`.
4. **Switch the native hotkey to Right ⌘** — in the native app's Settings,
   change the hotkey from Right ⌥ to `right_command`.
5. **Enable Launch at Login** — native Settings toggle
   (`SMAppService.mainApp`), replacing the Python launchd plist.

### Rollback

One command in reverse: re-run `make install-agent` to bring the Python
agent back on Right ⌘. The Python app is never deleted — both apps stay
in-repo permanently, Python as the oracle + eval harness the golden set and
model tests validate against.

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

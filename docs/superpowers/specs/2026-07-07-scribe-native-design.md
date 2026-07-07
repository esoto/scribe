# scribe-native — native Swift rewrite (design)

Date: 2026-07-07
Status: approved pending final user review
Predecessor: `2026-07-06-scribe-dictation-app-design.md` (the Python app — running,
validated, stays as daily driver and behavioral oracle until cutover)

## 1. Why a native rewrite

The Python app works end-to-end (confirmed with real dictations today), but its
unbundled-interpreter nature caused every setup landmine we hit on first run:
TCC grants attach to a hidden `Python.app` inside the Homebrew framework,
terminal-launched processes inherit the terminal's grants, Settings entries say
"Python" with a generic icon, and grants die on venv rebuilds or brew upgrades.
A real `.app` bundle makes all of that structural pain vanish and is the honest
road to Esteban's stated goal: a distributable app that sets up transparently
on any Mac ("copy, launch, three system dialogs, done").

Everything empirically hard-won ports 1:1: the cleanup prompt + few-shots, the
gate thresholds, the golden eval set, the state-machine semantics, the
degradation policy. The Swift work is translation against a working oracle.

## 2. Product behavior (unchanged from the validated spec)

Hold **Right ⌘** (≥ 0.3 s) → record → Parakeet v3 transcribes (EN/ES, mixed OK)
→ Gemma 3 4B cleans (fillers, self-corrections, punctuation; same-language
enforced) → paste into frontmost app with clipboard restore → last-10 history.
Cleanup degrades to raw on any failure. Menu bar glyphs ◦ ● ⋯ ⚠. Engine
switchable to Whisper. Idle unload reclaims model memory.

## 3. Architecture

- **Location:** `native/` directory in this repo (XcodeGen `project.yml`, like
  LocalMLX). Golden set + wav fixtures at `tests_models/` stay shared between
  Python reference and Swift app — one source of truth for correctness.
- **Stack:** Swift 6, SwiftUI `MenuBarExtra`, macOS 15+, Apple Silicon only.
  Bundle id `dev.esoto.scribe`. Ad-hoc signing for personal use (Developer ID
  + notarization deferred until/if publicly distributed).
- **Login item:** `SMAppService.mainApp` with a Settings toggle (replaces the
  launchd plist machinery).
- **Concurrency:** one `InferenceActor` owns all model loading and inference —
  the Swift-native equivalent of the Python `MlxThread` (which existed because
  MLX weights bind to their loading thread). Pipeline work runs on a serial
  dispatch/actor context; UI updates hop to MainActor.

### Components (seam rule preserved: adapters are logic-free)

| Component | Responsibility | Swift form |
|---|---|---|
| `DictationPipeline` | state machine `idle→recording→processing→idle`, FIFO queue, gates, degradation policy — identical semantics to Python `pipeline.py` | pure, injected deps |
| `HotkeyMonitor` | Right ⌘ / Right ⌥ / F13 hold detection, 0.3 s debounce, `CGEventTapIsEnabled` verified after install (macOS 26 silent-disable) | CGEventTap |
| `AudioRecorder` | pre-armed 16 kHz mono capture, ring buffer, reopen after device loss | AVAudioEngine |
| `SttEngine` (protocol) | `transcribe(pcm) -> String` | `ParakeetEngine` (FluidAudio/CoreML/ANE), `WhisperEngine` (WhisperKit large-v3-turbo) |
| `CleanupBackend` (protocol) | `clean(text) -> String` | `GemmaBackend` (MLX-Swift LLM, temp 0, **verbatim prompt + few-shot pairs from `src/scribe/cleanup/base.py`**) |
| `Gates` | energy gate (0.0005 RMS), min-words (4), length band (0.5–1.3), language consistency (same EN/ES stopword sets), normalize | pure |
| `Paster` | save → set → synthetic ⌘V → restore after 2.0 s, skipped if changeCount moved | NSPasteboard + CGEvent |
| `History` | last 10, in-memory only | pure |
| `MenuBar` | glyph state, engine switch, cleanup toggle, history (click = copy), Doctor/Setup, Settings, quit | MenuBarExtra |
| `Onboarding` | first-run permission flow (§5) | window + TCC request adapters |
| `Settings` | UserDefaults-backed; imports `~/.config/scribe/config.toml` values on first launch; native Settings window | SwiftUI |

Memory management ports too: only the active STT engine holds weights; idle
unload (default 15 min) drops everything; key-down pre-warms reload.

## 4. ML integration and its risks

- **Parakeet v3 via FluidAudio**: CoreML/ANE, ~0.19 s class latency, SDK
  handles model download/versioning. Powers Hex/VoiceInk and ~20 production
  apps — the ecosystem-proven path.
- **Whisper large-v3-turbo via WhisperKit**: fallback engine, menu-switchable,
  loads on first use.
- **Gemma 3 4B QAT via MLX-Swift** (`mlx-community/gemma-3-4b-it-qat-4bit`):
  same repo, temp 0, max_tokens = max(200, 2× input tokens). **This is risk #1**
  — mitigated by a day-one validation spike (see plan): a bare CLI target that
  loads Gemma through MLX-Swift and runs the full golden set. Plan B if red:
  Qwen3-4B-class instruct model, accepted only on a 10/10 ported eval.
- All macOS-26 empirical guards carry over: energy gate as primary silence
  defense, `condition_on_previous_text=false` equivalent for Whisper,
  no_speech filtering best-effort.

## 5. Onboarding (the point of the rewrite)

First launch opens a welcome window: three steps with live checkmarks.

1. Each step fires the native request API — `AVCaptureDevice.requestAccess`
   (mic), `AXIsProcessTrustedWithOptions(prompt: true)` (Accessibility),
   `CGRequestListenEventAccess()` (Input Monitoring). macOS shows its own
   dialog and **auto-adds "scribe" (name + icon) to the correct pane** — no
   paths, no "+", no hidden bundles.
2. A poll loop watches grants land (2 s cadence); Input Monitoring arrival
   triggers live tap installation — no restarts anywhere.
3. Per-step "Open Settings" buttons deep-link the exact pane
   (`x-apple.systempreferences:com.apple.preference.security?Privacy_…`) for
   the dismissed-dialog case.
4. All green → "Hold Right ⌘ and speak" with a try-it-now text field in the
   window.
5. The same window doubles as **Doctor** (menu item): grant status, model
   cache status, log location. Setup and diagnostics are one surface.

`OnboardingState` is pure (missing grants → next action/instruction) with
request/probe/deep-link calls injected — unit-tested like the Python doctor.

## 6. Error handling

The Python spec's table ports verbatim: STT failure → save wav + ⚠; cleanup
failure/timeout/gate-fail → paste raw, never block; paste failure → text stays
on clipboard + notification; mic loss → reopen on next key-down; model load
failure → app alive, hotkey disabled, Doctor explains. Logs via OSLog
(Console.app) plus a rotating file at `~/Library/Logs/scribe/` for
greppability.

## 7. Testing

1. **Unit (XCTest, no models)** — ported pure-logic suite: pipeline
   state machine incl. every degradation row, all gates, key state machine,
   paste restore, onboarding state, settings import. ~100% on pure logic;
   adapters excluded.
2. **Model integration** — shared fixtures (`tests_models/fixtures/*.wav`)
   against real FluidAudio, WhisperKit, MLX-Swift Gemma; silence-hallucination
   guard; actor-concurrency regression (Swift analog of the cross-thread test).
3. **Golden eval** — test target reads the shared `tests_models/golden.json`.
   **Parity gate: 10/10 required before cutover.** Behavior disputes during
   the port are settled by running the same input through the Python app.

## 8. Cutover plan (no dictation gap)

1. Development binding: **Right ⌥**, so both apps coexist (two taps on Right ⌘
   would double-paste).
2. Parity checklist: golden 10/10 + model tests green + rule-of-five human
   check (5 EN / 5 ES real dictations on both apps, outputs compared).
3. Switch: `make uninstall-agent` retires the Python agent; scribe-native
   moves to Right ⌘ and enables its login item.
4. Rollback: one command each direction; Python app remains in-repo
   permanently as reference + eval harness.

## 9. Risks, ranked

1. **MLX-Swift Gemma 3 support** — day-one spike; plan B Qwen3-4B (eval-gated).
2. **FluidAudio API drift / model availability** — validated in the same spike.
3. **Swift iteration speed** — mitigated by porting against a working oracle;
   plan orders pure-logic ports (fast, testable) before adapter work.
4. **Ad-hoc signing quirks** (TCC re-prompts after rebuilds during dev) — known
   from Hex's docs; use a stable dev signing identity; acceptable during
   development, gone at cutover.

## 10. Out of scope for v1

Public distribution (Developer ID, notarization, updates), iOS/other
platforms, streaming transcription, app-specific tone profiles, custom
vocabulary. The Python app's `apple-fm-sdk` experiment note carries over
unchanged.

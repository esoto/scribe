# scribe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build scribe — a local hold-to-talk dictation menu-bar app for macOS per the approved spec (`docs/superpowers/specs/2026-07-06-scribe-dictation-app-design.md`).

**Architecture:** One long-running Python process. OS adapters (hotkey tap, mic, pasteboard, menu bar) are logic-free shells; all decisions live in pure, injected-dependency modules tested to ~100%. Models: Parakeet v3 resident, mlx-whisper lazy, Gemma 3 4B resident behind `CleanupBackend`.

**Tech Stack:** Python 3.14 (arm64), mlx, parakeet-mlx 0.5.2, mlx-whisper 0.4.3, mlx-lm 0.31.3, sounddevice, rumps, pyobjc, numpy, pytest + pytest-cov.

## Global Constraints

- Repo: `~/development/scribe`; venv at `.venv` created from `python3` (3.14.3 verified on this machine); launchd must reference `.venv/bin/python` by absolute path (TCC).
- Pin exact model repos: `mlx-community/parakeet-tdt-0.6b-v3`, `mlx-community/whisper-large-v3-turbo`, `mlx-community/gemma-3-4b-it-qat-4bit` (all already in HF cache).
- Cleanup prompt is the validated text in spec §3 — copy verbatim, never paraphrase.
- Empirical guard (2026-07-07 probe): mlx-whisper hallucinated " Thank you." on near-silence with `no_speech_prob=0.0` → the RMS energy gate is the primary silence defense; always call mlx-whisper with `condition_on_previous_text=False`; `no_speech_prob > 0.6` filter is best-effort only.
- Every failure degrades to pasting/keeping raw text; never block or crash the app loop.
- Unit tests must not import mlx/models/OS frameworks; coverage `fail_under=95` overall with OS-adapter bodies excluded via `# pragma: no cover`.
- Conventional commits; never `--no-verify`.

**Verified API facts (probed on this machine, don't re-derive):**
- Parakeet array path: `mel = parakeet_mlx.audio.get_logmel(mx.array(pcm_f32), model.preprocessor_config)`; `model.generate(mel)` → `[AlignedResult]`, text at `.text`. `from_pretrained(repo)` loads in ~1.6 s.
- mlx-whisper array path: `mlx_whisper.transcribe(pcm_f32, path_or_hf_repo=repo, condition_on_previous_text=False)` → dict with `"text"` and `"segments"` (each has `no_speech_prob`).
- mlx-lm: `load(repo)`; `generate(model, tok, prompt=tok.apply_chat_template(msgs, add_generation_prompt=True), max_tokens=…, sampler=make_sampler(temp=0.0))`.
- Keycodes: right ⌘ = 54, right ⌥ = 61, F13 = 105, V = 9. Modifier events arrive as `kCGEventFlagsChanged` (type 12); F13 as keyDown/keyUp (10/11). Command mask = `0x100000`, Option mask = `0x80000`.

---

### Task 1: Scaffold + tooling

**Files:** Create `pyproject.toml`, `Makefile`, `src/scribe/__init__.py`, `tests/test_scaffold.py`.

**Interfaces:** Produces the package `scribe` (version string) and `make test` / `make cov`.

- [ ] **Step 1: write files**

`pyproject.toml`:
```toml
[build-system]
requires = ["setuptools>=69"]
build-backend = "setuptools.build_meta"

[project]
name = "scribe"
version = "0.1.0"
description = "Local hold-to-talk dictation for macOS (Parakeet/Whisper + Gemma cleanup)"
requires-python = ">=3.12"
dependencies = [
  "mlx>=0.31",
  "parakeet-mlx==0.5.2",
  "mlx-whisper==0.4.3",
  "mlx-lm==0.31.3",
  "numpy>=2.0",
  "sounddevice>=0.5",
  "rumps>=0.4",
  "pyobjc-framework-Quartz>=11",
  "pyobjc-framework-AVFoundation>=11",
]

[project.optional-dependencies]
dev = ["pytest>=8", "pytest-cov>=6"]

[project.scripts]
scribe = "scribe.app:main"

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = ["models: needs local MLX models (make test-models)"]

[tool.coverage.run]
source = ["scribe"]

[tool.coverage.report]
fail_under = 95
exclude_also = ["pragma: no cover", "if __name__ =="]
```

`src/scribe/__init__.py`:
```python
__version__ = "0.1.0"
```

`tests/test_scaffold.py`:
```python
import scribe

def test_package_imports():
    assert scribe.__version__ == "0.1.0"
```

`Makefile`:
```make
PY := .venv/bin/python
venv:
	python3 -m venv .venv && $(PY) -m pip install -q -e '.[dev]'
test:
	$(PY) -m pytest -q -m 'not models'
cov:
	$(PY) -m pytest -q -m 'not models' --cov --cov-report=term-missing
test-models:
	$(PY) -m pytest -q -m models tests_models
eval:
	$(PY) tests_models/run_eval.py
doctor:
	$(PY) -m scribe.doctor
run:
	$(PY) -m scribe
```

- [ ] **Step 2:** `make venv && make test` → 1 passed.
- [ ] **Step 3:** Commit `chore: scaffold package, venv, test tooling`.

---

### Task 2: config.py

**Files:** Create `src/scribe/config.py`, `tests/test_config.py`.

**Interfaces — Produces:**
`Config` frozen dataclass with nested `Hotkey(key: str, hold_threshold_s: float)`, `Stt(engine: str, parakeet_model: str, whisper_model: str)`, `Cleanup(enabled: bool, model: str, min_words: int, timeout_s: float, length_band: tuple[float, float])`, `Paste(clipboard_restore_delay_s: float)`, `Audio(sample_rate: int, energy_gate_rms: float)`, `Ui(sounds: bool, history_size: int)`.
`load_config(path: Path) -> tuple[Config, list[str]]` — missing file → defaults + no warnings; unparseable/invalid values → defaults for the bad field + warning strings. `DEFAULT_PATH = Path("~/.config/scribe/config.toml").expanduser()`.

- [ ] **Step 1: failing tests** (`tests/test_config.py`)

```python
from pathlib import Path
from scribe.config import Config, load_config

def test_defaults_when_missing(tmp_path):
    cfg, warns = load_config(tmp_path / "nope.toml")
    assert cfg.hotkey.key == "right_command"
    assert cfg.cleanup.length_band == (0.5, 1.3)
    assert warns == []

def test_full_parse(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text('[hotkey]\nkey="f13"\nhold_threshold_s=0.5\n[cleanup]\nenabled=false\nmin_words=2\n')
    cfg, warns = load_config(p)
    assert cfg.hotkey.key == "f13" and cfg.hotkey.hold_threshold_s == 0.5
    assert cfg.cleanup.enabled is False and cfg.cleanup.min_words == 2
    assert warns == []

def test_invalid_field_falls_back_with_warning(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text('[hotkey]\nkey="caps_lock"\n[cleanup]\nlength_band=[2.0,0.1]\n')
    cfg, warns = load_config(p)
    assert cfg.hotkey.key == "right_command"
    assert cfg.cleanup.length_band == (0.5, 1.3)
    assert len(warns) == 2

def test_unparseable_toml_all_defaults(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text("not [ toml")
    cfg, warns = load_config(p)
    assert cfg == load_config(tmp_path / "missing.toml")[0]
    assert warns

def test_unknown_keys_ignored(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text('[hotkey]\nbanana=1\n')
    cfg, warns = load_config(p)
    assert warns == []
```

- [ ] **Step 2:** run → FAIL (module missing).
- [ ] **Step 3: implement** — frozen dataclasses with the defaults from spec §4; `load_config` reads with `tomllib`, walks a `{section: {field: (caster, validator)}}` table, collecting warnings `f"{section}.{field}: invalid value {v!r}, using default"`. Valid keys for `hotkey.key`: `right_command`, `right_option`, `f13`. `length_band` valid iff `0 < lo < 1 <= hi <= 3`.
- [ ] **Step 4:** `make test` → pass. **Step 5:** commit `feat: typed config with tolerant TOML loading`.

---

### Task 3: history.py

**Files:** Create `src/scribe/history.py`, `tests/test_history.py`.

**Interfaces — Produces:** `Record(raw: str, final: str, engine: str, cleaned: bool, at: float, duration_ms: int)`; `History(maxlen: int)` with thread-safe `.append(Record)` and `.items() -> list[Record]` (newest first).

- [ ] **Step 1: failing tests**

```python
from scribe.history import History, Record

def rec(i):
    return Record(raw=f"r{i}", final=f"f{i}", engine="parakeet", cleaned=True, at=float(i), duration_ms=10)

def test_newest_first_and_bounded():
    h = History(maxlen=3)
    for i in range(5):
        h.append(rec(i))
    assert [r.raw for r in h.items()] == ["r4", "r3", "r2"]

def test_empty():
    assert History(maxlen=3).items() == []
```

- [ ] **Steps 2–5:** fail → implement (`collections.deque(maxlen=…)` + `threading.Lock`) → pass → commit `feat: bounded in-memory dictation history`.

---

### Task 4: gates.py (pure decision helpers)

**Files:** Create `src/scribe/gates.py`, `tests/test_gates.py`.

**Interfaces — Produces:**
`rms(pcm: np.ndarray) -> float`; `passes_energy_gate(pcm, threshold: float) -> bool` (empty array → False); `should_clean(text: str, *, enabled: bool, min_words: int) -> bool`; `length_ok(raw: str, cleaned: str, band: tuple[float, float]) -> bool`; `normalize(text: str) -> str` (strip + collapse internal whitespace runs to single spaces, preserve case/accents).

- [ ] **Step 1: failing tests**

```python
import numpy as np
from scribe.gates import rms, passes_energy_gate, should_clean, length_ok, normalize

def test_rms_silence_vs_tone():
    silent = np.zeros(1600, dtype=np.float32)
    tone = (0.1 * np.sin(np.linspace(0, 100, 1600))).astype(np.float32)
    assert rms(silent) == 0.0
    assert rms(tone) > 0.05

def test_energy_gate():
    assert not passes_energy_gate(np.zeros(100, dtype=np.float32), 0.005)
    assert not passes_energy_gate(np.zeros(0, dtype=np.float32), 0.005)
    assert passes_energy_gate(np.full(100, 0.1, dtype=np.float32), 0.005)

def test_should_clean():
    assert should_clean("one two three four", enabled=True, min_words=4)
    assert not should_clean("one two three", enabled=True, min_words=4)
    assert not should_clean("one two three four", enabled=False, min_words=4)

def test_length_ok():
    band = (0.5, 1.3)
    assert length_ok("a" * 100, "a" * 80, band)
    assert not length_ok("a" * 100, "a" * 20, band)   # truncation
    assert not length_ok("a" * 100, "a" * 200, band)  # over-generation
    assert not length_ok("hello", "", band)

def test_normalize_preserves_spanish():
    assert normalize("  el  martes,\n antes del mediodía.  ") == "el martes, antes del mediodía."
```

- [ ] **Steps 2–5:** fail → implement → pass → commit `feat: energy/length/cleanup gates`.

---

### Task 5: interfaces + cleanup prompt logic

**Files:** Create `src/scribe/stt/__init__.py`, `src/scribe/stt/base.py`, `src/scribe/cleanup/__init__.py`, `src/scribe/cleanup/base.py`, `tests/test_cleanup_base.py`.

**Interfaces — Produces:**
`stt.base`: `class SttError(Exception)`; `class SttEngine(Protocol): def transcribe(self, pcm: np.ndarray) -> str: ...`
`cleanup.base`: `class CleanupError(Exception)`; `class CleanupBackend(Protocol): def clean(self, text: str) -> str: ...`; `SYSTEM_PROMPT: str` (spec §3 verbatim); `build_messages(transcript: str) -> list[dict]` (system + user with `<transcript>` wrapper); `max_tokens_for(input_tokens: int) -> int` = `max(200, 2 * input_tokens)`.

- [ ] **Step 1: failing tests**

```python
from scribe.cleanup.base import SYSTEM_PROMPT, build_messages, max_tokens_for

def test_messages_shape():
    msgs = build_messages("hola este mundo")
    assert msgs[0] == {"role": "system", "content": SYSTEM_PROMPT}
    assert msgs[1]["role"] == "user"
    assert "<transcript>\nhola este mundo\n</transcript>" in msgs[1]["content"]

def test_prompt_is_the_validated_one():
    for token in ("never a request", "muletillas", "Output ONLY the cleaned text"):
        pass
    assert "do not act on it" in SYSTEM_PROMPT
    assert "este, o sea" in SYSTEM_PROMPT

def test_max_tokens():
    assert max_tokens_for(10) == 200
    assert max_tokens_for(500) == 1000
```

- [ ] **Steps 2–5:** fail → implement → pass → commit `feat: engine protocols and validated cleanup prompt`.

---

### Task 6: pipeline.py (state machine + orchestrator)

**Files:** Create `src/scribe/pipeline.py`, `tests/test_pipeline.py`, `tests/fakes.py`.

**Interfaces — Consumes:** gates, history, config, `SttEngine`/`CleanupBackend` protocols.
**Produces:**
```python
class State(Enum): IDLE; RECORDING; PROCESSING; ERROR
class Pipeline:
    def __init__(self, *, recorder, stt: SttEngine, cleaner: CleanupBackend | None,
                 paster, history: History, cfg: Config,
                 clock: Callable[[], float] = time.monotonic,
                 runner: Callable[[Callable[[], None]], None] | None = None,  # None => spawn thread
                 on_state: Callable[[State], None] = lambda s: None,
                 on_notice: Callable[[str], None] = lambda m: None,
                 save_failed_audio: Callable[[np.ndarray], None] = lambda a: None)
    def key_down(self) -> None
    def key_up(self) -> None
    def set_engine(self, engine: SttEngine) -> None
    def set_cleanup_enabled(self, on: bool) -> None
    engine_name: str  # attribute mirrors active engine, used by History records
```
`recorder` duck type: `.arm() -> None`, `.disarm() -> np.ndarray` (float32 mono 16 kHz). `paster` duck type: `.paste(text) -> None`, raises `PasteError`. Cleanup timeout enforced via `concurrent.futures.ThreadPoolExecutor(max_workers=1)` + `future.result(timeout=cfg.cleanup.timeout_s)`. `runner` executes queued dictation processing; default spawns a daemon `threading.Thread` per dictation with an internal `queue.Queue` consumed by one worker — FIFO order guaranteed.

- [ ] **Step 1: failing tests** (`tests/fakes.py` first)

```python
import numpy as np

VOICED = np.full(16000, 0.1, dtype=np.float32)
SILENT = np.zeros(16000, dtype=np.float32)

class FakeRecorder:
    def __init__(self, pcm=VOICED):
        self.pcm, self.armed = pcm, False
    def arm(self):
        self.armed = True
    def disarm(self):
        self.armed = False
        return self.pcm

class FakeStt:
    def __init__(self, text="so um hello there world", err=None):
        self.text, self.err, self.calls = text, err, 0
    def transcribe(self, pcm):
        self.calls += 1
        if self.err:
            raise self.err
        return self.text

class FakeCleaner:
    def __init__(self, out="hello there world", err=None, delay=0.0):
        self.out, self.err, self.delay, self.calls = out, err, delay, 0
    def clean(self, text):
        import time
        self.calls += 1
        if self.delay:
            time.sleep(self.delay)
        if self.err:
            raise self.err
        return self.out

class FakePaster:
    def __init__(self, err=None):
        self.err, self.pasted = err, []
    def paste(self, text):
        if self.err:
            raise self.err
        self.pasted.append(text)

class FakeClock:
    def __init__(self):
        self.t = 0.0
    def __call__(self):
        return self.t
```

`tests/test_pipeline.py` — every row of spec §5 plus lifecycle:

```python
import numpy as np
import pytest
from scribe.config import load_config
from scribe.history import History
from scribe.paste import PasteError
from scribe.pipeline import Pipeline, State
from scribe.stt.base import SttError
from tests.fakes import FakeRecorder, FakeStt, FakeCleaner, FakePaster, FakeClock, VOICED, SILENT

def make(**kw):
    cfg, _ = load_config(kw.pop("cfg_path", __import__("pathlib").Path("/nonexistent")))
    clock = FakeClock()
    states, notices, saved = [], [], []
    p = Pipeline(
        recorder=kw.pop("recorder", FakeRecorder()),
        stt=kw.pop("stt", FakeStt()),
        cleaner=kw.pop("cleaner", FakeCleaner()),
        paster=kw.pop("paster", FakePaster()),
        history=kw.pop("history", History(10)),
        cfg=kw.pop("cfg", cfg),
        clock=clock,
        runner=lambda f: f(),          # synchronous for tests
        on_state=states.append,
        on_notice=notices.append,
        save_failed_audio=saved.append,
        **kw,
    )
    return p, clock, states, notices, saved

def dictate(p, clock, hold=1.0):
    p.key_down()
    clock.t += hold
    p.key_up()

def test_happy_path_cleans_and_pastes():
    paster = FakePaster()
    hist = History(10)
    p, clock, states, _, _ = make(paster=paster, history=hist)
    dictate(p, clock)
    assert paster.pasted == ["hello there world"]
    assert hist.items()[0].raw == "so um hello there world"
    assert hist.items()[0].cleaned is True
    assert states[-1] == State.IDLE and State.RECORDING in states and State.PROCESSING in states

def test_sub_threshold_tap_discarded():
    stt = FakeStt()
    p, clock, *_ = make(stt=stt)
    dictate(p, clock, hold=0.1)
    assert stt.calls == 0

def test_energy_gate_discards_silence():
    stt = FakeStt()
    p, clock, *_ = make(recorder=FakeRecorder(pcm=SILENT), stt=stt)
    dictate(p, clock)
    assert stt.calls == 0

def test_short_utterance_skips_cleanup():
    cleaner, paster = FakeCleaner(), FakePaster()
    p, clock, *_ = make(stt=FakeStt(text="just three words"), cleaner=cleaner, paster=paster)
    dictate(p, clock)
    assert cleaner.calls == 0
    assert paster.pasted == ["just three words"]

def test_cleanup_disabled_skips():
    cleaner, paster = FakeCleaner(), FakePaster()
    p, clock, *_ = make(cleaner=cleaner, paster=paster)
    p.set_cleanup_enabled(False)
    dictate(p, clock)
    assert cleaner.calls == 0 and paster.pasted == ["so um hello there world"]

def test_cleanup_error_falls_back_to_raw():
    paster = FakePaster()
    p, clock, *_ = make(cleaner=FakeCleaner(err=RuntimeError("boom")), paster=paster)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]

def test_cleanup_timeout_falls_back_to_raw():
    paster = FakePaster()
    cfg, _ = load_config(__import__("pathlib").Path("/nonexistent"))
    cfg = __import__("dataclasses").replace(cfg, cleanup=__import__("dataclasses").replace(cfg.cleanup, timeout_s=0.01))
    p, clock, *_ = make(cleaner=FakeCleaner(delay=0.2), paster=paster, cfg=cfg)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]

def test_cleanup_length_gate_falls_back():
    paster = FakePaster()
    p, clock, *_ = make(cleaner=FakeCleaner(out="x"), paster=paster)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]

def test_cleanup_empty_falls_back():
    paster = FakePaster()
    p, clock, *_ = make(cleaner=FakeCleaner(out="   "), paster=paster)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]

def test_stt_error_saves_audio_and_notifies():
    paster = FakePaster()
    p, clock, states, notices, saved = make(stt=FakeStt(err=SttError("dead")), paster=paster)
    dictate(p, clock)
    assert paster.pasted == []
    assert len(saved) == 1 and isinstance(saved[0], np.ndarray)
    assert notices and State.ERROR in states

def test_stt_empty_discards_with_notice():
    paster = FakePaster()
    p, clock, _, notices, _ = make(stt=FakeStt(text="  "), paster=paster)
    dictate(p, clock)
    assert paster.pasted == [] and notices

def test_paste_error_notifies_manual_paste():
    p, clock, _, notices, _ = make(paster=FakePaster(err=PasteError("secure input")))
    dictate(p, clock)
    assert any("⌘V" in n for n in notices)

def test_history_records_engine_and_raw_final():
    hist = History(10)
    p, clock, *_ = make(history=hist)
    dictate(p, clock)
    r = hist.items()[0]
    assert r.engine == "parakeet" and r.final == "hello there world"

def test_engine_swap():
    paster = FakePaster()
    p, clock, *_ = make(paster=paster)
    p.set_engine(FakeStt(text="desde whisper aquí cuatro"), name="whisper")
    dictate(p, clock)
    assert p.engine_name == "whisper"

def test_two_dictations_fifo():
    paster = FakePaster()
    p, clock, *_ = make(paster=paster)
    dictate(p, clock)
    dictate(p, clock)
    assert len(paster.pasted) == 2
```

- [ ] **Step 2:** run → FAIL. **Step 3: implement** exactly per the flow in spec §3 (energy gate → transcribe → normalize/empty check → cleanup decision → timeout+gates → paste → history). `set_engine(engine, name="whisper")` signature. ERROR state is a transient flash: emit `State.ERROR` then `State.IDLE`.
- [ ] **Step 4:** pass. **Step 5:** commit `feat: dictation pipeline state machine with degradation paths`.

---

### Task 7: STT adapters

**Files:** Create `src/scribe/stt/parakeet.py`, `src/scribe/stt/whisper.py`, `tests/test_whisper_segments.py`.

**Interfaces — Produces:** `ParakeetEngine(model_repo).transcribe(pcm)->str` (loads at construction; `# pragma: no cover` body); `WhisperEngine(model_repo)` lazy — first `transcribe` triggers model download/load; module-level pure `join_segments(segments: list[dict], threshold: float = 0.6) -> str`.

- [ ] **Step 1: failing test** (pure part only)

```python
from scribe.stt.whisper import join_segments

def test_joins_and_filters_no_speech():
    segs = [
        {"text": " Hola.", "no_speech_prob": 0.01},
        {"text": " Thank you.", "no_speech_prob": 0.93},
        {"text": " ¿Qué tal?", "no_speech_prob": 0.2},
    ]
    assert join_segments(segs) == "Hola. ¿Qué tal?"

def test_empty_segments():
    assert join_segments([]) == ""

def test_missing_prob_key_kept():
    assert join_segments([{"text": " hi"}]) == "hi"
```

- [ ] **Step 2–4:** fail → implement. Adapters (imports inside methods so unit tests never touch mlx):

```python
# parakeet.py
import numpy as np
from scribe.stt.base import SttError

class ParakeetEngine:
    name = "parakeet"
    def __init__(self, model_repo: str):  # pragma: no cover - loads MLX model
        from parakeet_mlx import from_pretrained
        self._model = from_pretrained(model_repo)
    def transcribe(self, pcm: np.ndarray) -> str:  # pragma: no cover - MLX inference
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel
        try:
            mel = get_logmel(mx.array(pcm), self._model.preprocessor_config)
            results = self._model.generate(mel)
            return " ".join(r.text.strip() for r in results if r.text.strip())
        except Exception as e:
            raise SttError(str(e)) from e
```

```python
# whisper.py
import numpy as np
from scribe.stt.base import SttError

def join_segments(segments, threshold: float = 0.6) -> str:
    kept = [s["text"].strip() for s in segments if s.get("no_speech_prob", 0.0) <= threshold and s["text"].strip()]
    return " ".join(kept)

class WhisperEngine:
    name = "whisper"
    def __init__(self, model_repo: str):
        self._repo, self._ready = model_repo, False
    def transcribe(self, pcm: np.ndarray) -> str:  # pragma: no cover - MLX inference
        try:
            import mlx_whisper
            r = mlx_whisper.transcribe(pcm, path_or_hf_repo=self._repo, condition_on_previous_text=False)
            self._ready = True
            return join_segments(r.get("segments", []))
        except Exception as e:
            raise SttError(str(e)) from e
```

- [ ] **Step 5:** commit `feat: parakeet and whisper STT adapters with hallucination filter`.

---

### Task 8: cleanup adapter

**Files:** Create `src/scribe/cleanup/mlx_lm.py`.

**Interfaces — Produces:** `MlxLmBackend(model_repo).clean(text) -> str`; raises `CleanupError` on any internal failure. Uses `build_messages` / `max_tokens_for` from Task 5, temp 0.

```python
from scribe.cleanup.base import CleanupError, build_messages, max_tokens_for

class MlxLmBackend:
    def __init__(self, model_repo: str):  # pragma: no cover - loads MLX model
        from mlx_lm import load
        self._model, self._tok = load(model_repo)
    def clean(self, text: str) -> str:  # pragma: no cover - MLX inference
        try:
            from mlx_lm import generate
            from mlx_lm.sample_utils import make_sampler
            prompt = self._tok.apply_chat_template(build_messages(text), add_generation_prompt=True)
            n_in = len(self._tok.encode(text))
            return generate(self._model, self._tok, prompt=prompt,
                            max_tokens=max_tokens_for(n_in), sampler=make_sampler(temp=0.0))
        except Exception as e:
            raise CleanupError(str(e)) from e
```

- [ ] Steps: implement (no new pure logic ⇒ no new unit tests; covered by Task 15 tier-2), `make test` stays green, commit `feat: mlx-lm Gemma cleanup backend`.

---

### Task 9: recorder.py

**Files:** Create `src/scribe/recorder.py`, `tests/test_recorder.py`.

**Interfaces — Produces:** `RecorderError(Exception)`; `RingBuffer(max_seconds, sample_rate)` with `.append(chunk)`, `.drain() -> np.ndarray`, `.clear()`, drops appends past capacity; `Recorder(stream_factory, sample_rate=16000, max_seconds=300)` with `.start()`, `.arm()`, `.disarm() -> np.ndarray`, `.ensure_stream()`; `_callback(indata)` appends `indata[:, 0].copy()` only when armed. `stream_factory(callback) -> stream` where stream has `.start()`, `.stop()`, `.close()`, `.active: bool`.

- [ ] **Step 1: failing tests**

```python
import numpy as np
import pytest
from scribe.recorder import Recorder, RecorderError, RingBuffer

def chunk(v, n=160):
    return np.full((n, 1), v, dtype=np.float32)

class FakeStream:
    def __init__(self, fail=False):
        self.active, self.fail = False, fail
    def start(self):
        if self.fail:
            raise OSError("no device")
        self.active = True
    def stop(self):
        self.active = False
    def close(self):
        self.active = False

def test_ring_buffer_drain_concatenates():
    rb = RingBuffer(max_seconds=1, sample_rate=160)
    rb.append(np.ones(80, dtype=np.float32))
    rb.append(np.zeros(80, dtype=np.float32))
    out = rb.drain()
    assert out.shape == (160,) and out[0] == 1.0 and out[-1] == 0.0
    assert rb.drain().shape == (0,)

def test_ring_buffer_caps_capacity():
    rb = RingBuffer(max_seconds=1, sample_rate=160)
    for _ in range(5):
        rb.append(np.ones(80, dtype=np.float32))
    assert rb.drain().shape[0] <= 160

def test_recorder_captures_only_while_armed():
    streams = []
    def factory(cb):
        streams.append(FakeStream())
        factory.cb = cb
        return streams[-1]
    r = Recorder(factory)
    r.start()
    factory.cb(chunk(0.5))
    r.arm()
    factory.cb(chunk(1.0))
    pcm = r.disarm()
    factory.cb(chunk(0.7))
    assert np.all(pcm == 1.0)

def test_ensure_stream_reopens_dead_stream():
    streams = []
    def factory(cb):
        streams.append(FakeStream())
        return streams[-1]
    r = Recorder(factory)
    r.start()
    streams[0].active = False
    r.ensure_stream()
    assert len(streams) == 2 and streams[1].active

def test_ensure_stream_raises_when_reopen_fails():
    def factory(cb):
        return FakeStream(fail=True)
    r = Recorder(factory)
    with pytest.raises(RecorderError):
        r.ensure_stream()
```

- [ ] **Steps 2–4:** fail → implement (real `stream_factory` in `default_stream_factory(callback)` using `sounddevice.InputStream(samplerate=16000, channels=1, dtype="float32", callback=…)`, `# pragma: no cover`) → pass.
- [ ] **Step 5:** commit `feat: pre-opened recorder with armed ring buffer`.

---

### Task 10: hotkey.py

**Files:** Create `src/scribe/hotkey.py`, `tests/test_hotkey.py`.

**Interfaces — Produces:** `KEYCODES = {"right_command": 54, "right_option": 61, "f13": 105}`; `MODIFIER_MASKS = {54: 0x100000, 61: 0x80000}`; `KeyStateMachine(key: str)` with `.handle(event_type: int, keycode: int, flags: int) -> str | None` returning `"down"` / `"up"` / `None`. Event types: 10 keyDown, 11 keyUp, 12 flagsChanged. `HotkeyListener(key, on_down, on_up)` adapter wraps a CGEventTap on the current run loop (`# pragma: no cover`).

- [ ] **Step 1: failing tests**

```python
from scribe.hotkey import KeyStateMachine

CMD = 0x100000

def test_right_command_down_up():
    m = KeyStateMachine("right_command")
    assert m.handle(12, 54, CMD) == "down"
    assert m.handle(12, 54, 0) == "up"

def test_other_keycode_ignored():
    m = KeyStateMachine("right_command")
    assert m.handle(12, 55, CMD) is None      # left cmd
    assert m.handle(12, 61, 0x80000) is None  # right opt

def test_duplicate_flags_events_ignored():
    m = KeyStateMachine("right_command")
    assert m.handle(12, 54, CMD) == "down"
    assert m.handle(12, 54, CMD) is None
    assert m.handle(12, 54, 0) == "up"
    assert m.handle(12, 54, 0) is None

def test_f13_uses_keydown_keyup():
    m = KeyStateMachine("f13")
    assert m.handle(10, 105, 0) == "down"
    assert m.handle(11, 105, 0) == "up"
    assert m.handle(12, 105, 0) is None
```

- [ ] **Steps 2–4:** fail → implement → pass. Adapter body:

```python
class HotkeyListener:  # pragma: no cover - CGEventTap wiring
    def __init__(self, key, on_down, on_up):
        self._m, self._down, self._up = KeyStateMachine(key), on_down, on_up
    def install(self):
        import Quartz
        mask = (Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged)
                | Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
                | Quartz.CGEventMaskBit(Quartz.kCGEventKeyUp))
        def cb(proxy, etype, event, refcon):
            keycode = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode)
            action = self._m.handle(int(etype), int(keycode), int(Quartz.CGEventGetFlags(event)))
            if action == "down":
                self._down()
            elif action == "up":
                self._up()
            return event
        tap = Quartz.CGEventTapCreate(Quartz.kCGSessionEventTap, Quartz.kCGHeadInsertEventTap,
                                      Quartz.kCGEventTapOptionListenOnly, mask, cb, None)
        if tap is None:
            raise PermissionError("event tap denied — grant Input Monitoring")
        src = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
        Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), src, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(tap, True)
        self._tap = tap
```

- [ ] **Step 5:** commit `feat: hold-to-talk key state machine + event tap adapter`.

---

### Task 11: paste.py

**Files:** Create `src/scribe/paste.py`, `tests/test_paste.py`.

**Interfaces — Produces:** `PasteError(Exception)`; `Paster(pasteboard, post_cmd_v, schedule, restore_delay_s)` — `pasteboard` duck: `.get() -> str | None`, `.set(str)`, `.change_count() -> int`; `schedule(delay_s, fn)`; `.paste(text)` per spec §3 step 6 plus: restore is **skipped** if the pasteboard changed since we set it (user copied something meanwhile). `MacPasteboard` and `post_cmd_v()` real adapters (`# pragma: no cover`).

- [ ] **Step 1: failing tests**

```python
import pytest
from scribe.paste import Paster, PasteError

class FakePb:
    def __init__(self, initial="old stuff"):
        self._v, self._count = initial, 1
    def get(self):
        return self._v
    def set(self, v):
        self._v, self._count = v, self._count + 1
    def change_count(self):
        return self._count

class Sched:
    def __init__(self):
        self.jobs = []
    def __call__(self, delay, fn):
        self.jobs.append((delay, fn))
    def fire(self):
        for _, fn in self.jobs:
            fn()

def test_paste_sets_posts_and_restores():
    pb, sched, posts = FakePb(), Sched(), []
    p = Paster(pb, lambda: posts.append(1), sched, 2.0)
    p.paste("nuevo texto")
    assert pb.get() == "nuevo texto" and posts == [1]
    assert sched.jobs[0][0] == 2.0
    sched.fire()
    assert pb.get() == "old stuff"

def test_restore_skipped_if_user_copied_meanwhile():
    pb, sched = FakePb(), Sched()
    p = Paster(pb, lambda: None, sched, 2.0)
    p.paste("nuevo")
    pb.set("user copied this")
    sched.fire()
    assert pb.get() == "user copied this"

def test_empty_clipboard_no_restore_scheduled():
    pb, sched = FakePb(initial=None), Sched()
    Paster(pb, lambda: None, sched, 2.0).paste("hola")
    assert sched.jobs == []

def test_post_failure_raises_and_keeps_text_on_clipboard():
    pb, sched = FakePb(), Sched()
    def boom():
        raise OSError("secure input")
    p = Paster(pb, boom, sched, 2.0)
    with pytest.raises(PasteError):
        p.paste("texto")
    assert pb.get() == "texto" and sched.jobs == []
```

- [ ] **Steps 2–4:** fail → implement → pass. Real adapters:

```python
class MacPasteboard:  # pragma: no cover
    def __init__(self):
        from AppKit import NSPasteboard
        self._pb = NSPasteboard.generalPasteboard()
    def get(self):
        from AppKit import NSPasteboardTypeString
        v = self._pb.stringForType_(NSPasteboardTypeString)
        return str(v) if v is not None else None
    def set(self, v):
        from AppKit import NSPasteboardTypeString
        self._pb.clearContents()
        self._pb.setString_forType_(v, NSPasteboardTypeString)
    def change_count(self):
        return int(self._pb.changeCount())

def post_cmd_v():  # pragma: no cover
    import Quartz
    for down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(None, 9, down)
        Quartz.CGEventSetFlags(ev, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

def timer_schedule(delay_s, fn):  # pragma: no cover
    import threading
    t = threading.Timer(delay_s, fn)
    t.daemon = True
    t.start()
```

- [ ] **Step 5:** commit `feat: clipboard paste with safe restore`.

---

### Task 12: doctor.py

**Files:** Create `src/scribe/doctor.py`, `tests/test_doctor.py`.

**Interfaces — Produces:** `Check(name: str, ok: bool, hint: str)`; `run_checks(probes: dict[str, tuple[Callable[[], bool], str]]) -> list[Check]` (probe exception ⇒ not-ok with hint + error); `format_report(checks) -> str` (✓/✗ lines + failing hints); `default_probes() -> dict` with mic (`AVCaptureDevice.authorizationStatusForMediaType_` == 3), accessibility (`AXIsProcessTrusted`), input monitoring (`Quartz.CGPreflightListenEventAccess`), models-cached (HF cache dirs exist) — all `# pragma: no cover`; `main()` prints report, exit 0 iff all ok. Hints name the exact System Settings pane, e.g. `"System Settings → Privacy & Security → Microphone"`.

- [ ] **Step 1: failing tests**

```python
from scribe.doctor import Check, format_report, run_checks

def test_run_checks_ok_and_fail_and_crash():
    probes = {
        "mic": (lambda: True, "hint-mic"),
        "ax": (lambda: False, "hint-ax"),
        "boom": (lambda: 1 / 0, "hint-boom"),
    }
    checks = run_checks(probes)
    assert [c.ok for c in checks] == [True, False, False]
    assert "hint-boom" in checks[2].hint

def test_format_report():
    out = format_report([Check("mic", True, "h1"), Check("ax", False, "System Settings → Accessibility")])
    assert "✓ mic" in out and "✗ ax" in out and "Accessibility" in out
```

- [ ] **Steps 2–5:** fail → implement → pass → commit `feat: permission/model doctor`.

---

### Task 13: menubar.py + app.py + logging

**Files:** Create `src/scribe/menubar.py`, `src/scribe/app.py`, `src/scribe/__main__.py`, `tests/test_menubar_helpers.py`.

**Interfaces — Consumes:** everything above. **Produces:** pure helpers `glyph_for(state: State) -> str` (IDLE `"◦"`, RECORDING `"●"`, PROCESSING `"⋯"`, ERROR `"⚠"`), `truncate_label(text, n=40)`; `ScribeApp(rumps.App)` and `main()` (all `# pragma: no cover`). `__main__.py` calls `main()`.

- [ ] **Step 1: failing tests**

```python
from scribe.menubar import glyph_for, truncate_label
from scribe.pipeline import State

def test_glyphs():
    assert glyph_for(State.IDLE) == "◦"
    assert glyph_for(State.RECORDING) == "●"
    assert glyph_for(State.PROCESSING) == "⋯"
    assert glyph_for(State.ERROR) == "⚠"

def test_truncate():
    assert truncate_label("corto") == "corto"
    long = "x" * 60
    assert truncate_label(long) == "x" * 39 + "…"
```

- [ ] **Steps 2–4:** implement helpers, then app wiring (`# pragma: no cover` on the classes/functions below):
  - `main()`: set up rotating log (`logging.handlers.RotatingFileHandler`, `~/.local/state/scribe/scribe.log`, 7 backups), load config (log warnings), build components — models loaded lazily *after* the menu bar shows (background thread) so startup is instant; on model-load failure keep app alive, show ⚠ + disable hotkey (spec §5).
  - `ScribeApp(rumps.App)`: title = glyph; menu: `Engine → Parakeet ✓ / Whisper`, `Cleanup ✓`, `History` (submenu; item click copies final text back to clipboard), `Doctor` (runs `run_checks(default_probes())`, shows via `rumps.alert`), `Reload config`, `Quit`.
  - UI updates from worker threads hop to main: `NSOperationQueue.mainQueue().addOperationWithBlock_(fn)`.
  - Sounds via `AppKit.NSSound.soundNamed_("Pop"/"Basso").play()` gated on `cfg.ui.sounds`.
  - `save_failed_audio`: write float32→int16 WAV via `wave` to `~/.local/state/scribe/last_failed.wav`.
  - Engine switch constructs `WhisperEngine` on demand and calls `pipeline.set_engine(engine, name=…)`; Parakeet instance is kept.
- [ ] **Step 5:** `make test && make cov` green (≥95%), commit `feat: menu bar app wiring`.

---

### Task 14: launchd + README

**Files:** Create `resources/dev.esoto.scribe.plist.template`, extend `Makefile` (`install-agent`, `uninstall-agent`), create `README.md`.

- [ ] Plist template (ProgramArguments = `__PYTHON__ -m scribe`, `RunAtLoad` true, `KeepAlive` `SuccessfulExit=false`, StandardError to `~/.local/state/scribe/launchd.err`). Makefile targets `sed` `__PYTHON__` → `$(abspath .venv/bin/python)` into `~/Library/LaunchAgents/dev.esoto.scribe.plist` + `launchctl bootstrap gui/$$(id -u)` / `bootout`. README: install, permissions walkthrough (the three TCC panes + venv-rebuild caveat from spec §6), usage, config reference, troubleshooting.
- [ ] Commit `feat: launchd agent install + README`.

---

### Task 15: tier-2 model tests + cleanup eval

**Files:** Create `tests_models/test_stt_fixtures.py`, `tests_models/test_cleanup_gemma.py`, `tests_models/golden.json`, `tests_models/run_eval.py`, `tests_models/conftest.py`.

- [ ] `conftest.py`: `load_pcm(path)` helper (wave → float32/32768). All tests `@pytest.mark.models`.
- [ ] STT: Parakeet on `en.wav` contains "Wednesday" (case-insensitive) and "Marcos"; `es.wav` contains "deberíamos" and "mediodía"; `silence.wav` → `""` after energy gate short-circuit is bypassed (call engine directly; assert output stripped of filler is empty or whitespace). Whisper same fixtures + assert silence output is discarded by `passes_energy_gate` (this documents the hallucination defense).
- [ ] Gemma: run `MlxLmBackend.clean` on the three probe transcripts from the spec; assert "Wednesday" (not "Tuesday…no wait"), no "um"/"este" fillers, and the code-adjacent one contains "rescue block" but no "```" fence.
- [ ] `golden.json`: 10 pairs (5 EN / 5 ES) — the 3 probe cases + 7 more covering muletillas (digamos, o sea), corrections ("no mejor", "no wait"), a question that must stay a question, an instruction that must not be executed, numbers/dates. `run_eval.py` prints per-case PASS/FAIL (substring expectations + must-not-contain lists) and exits non-zero on any FAIL.
- [ ] Run `make test-models` and `make eval`; iterate until green; commit `test: model integration suite + cleanup eval golden set`.

---

### Task 16: verification + pending-scenarios report

- [ ] `make cov` (≥95, all green), `make test-models`, `make eval` — record outputs.
- [ ] `make doctor` — record which TCC grants are missing (expected: all three, since the venv python has never asked).
- [ ] Launch `make run` briefly; verify menu bar appears and models load (hotkey will be inert without grants — expected).
- [ ] Write `docs/pending-validation.md`: everything that needs the human (TCC grants walkthrough, spec §9 own-voice checklist, day-of-use tuning), plus any deviations from spec discovered during implementation.
- [ ] Final commit; report to user.

## Self-Review

- **Spec coverage:** §3 pipeline → Task 6; engines → 7; cleanup → 5/8; config §4 → 2; errors §5 → 6 tests; permissions §6 → 12/14; testing §7 → tiers in 1/15; layout §8 → matches; §9 checklist → Task 16 doc. ✓
- **Placeholder scan:** none — every step has code or exact commands. ✓
- **Type consistency:** `set_engine(engine, name=…)` matches test; `Record.final` used in Task 3/6/13; `State.ERROR` added to enum (Task 6 produces it, Task 13 maps it). ✓

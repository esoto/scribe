"""Dictation orchestrator: state machine + degradation policy.

Pure logic — every collaborator is injected, so the whole failure matrix in
spec §5 is unit-testable without hardware or models.
"""

from __future__ import annotations

import concurrent.futures
import logging
import queue
import threading
import time
from enum import Enum, auto
from typing import Callable

import numpy as np

from scribe import gates
from scribe.config import Config
from scribe.history import History, Record
from scribe.paste import PasteError
from scribe.stt.base import SttError

log = logging.getLogger(__name__)


class State(Enum):
    IDLE = auto()
    RECORDING = auto()
    PROCESSING = auto()
    ERROR = auto()


class Pipeline:
    def __init__(
        self,
        *,
        recorder,
        stt,
        cleaner,
        paster,
        history: History,
        cfg: Config,
        clock: Callable[[], float] = time.monotonic,
        runner: Callable[[Callable[[], None]], None] | None = None,
        on_state: Callable[[State], None] = lambda s: None,
        on_notice: Callable[[str], None] = lambda m: None,
        save_failed_audio: Callable[[np.ndarray], None] = lambda a: None,
    ):
        self._recorder = recorder
        self._stt = stt
        self.engine_name = getattr(stt, "name", "unknown")
        self._cleaner = cleaner
        self._cleanup_enabled = cfg.cleanup.enabled
        self._paster = paster
        self._history = history
        self._cfg = cfg
        self._clock = clock
        self._runner = runner if runner is not None else self._thread_runner
        self._on_state = on_state
        self._on_notice = on_notice
        self._save_failed_audio = save_failed_audio
        self._down_at: float | None = None
        self._cleanup_pool = concurrent.futures.ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="scribe-cleanup"
        )
        self._work_queue: queue.Queue | None = None

    def key_down(self) -> None:
        self._recorder.arm()
        self._down_at = self._clock()
        self._on_state(State.RECORDING)

    def key_up(self) -> None:
        pcm = self._recorder.disarm()
        held = self._clock() - (self._down_at or 0.0)
        if held < self._cfg.hotkey.hold_threshold_s:
            self._on_state(State.IDLE)
            return
        self._runner(lambda: self._process(pcm))

    def set_engine(self, engine, name: str | None = None) -> None:
        self._stt = engine
        self.engine_name = name or getattr(engine, "name", "unknown")

    def set_cleanup_enabled(self, on: bool) -> None:
        self._cleanup_enabled = on

    def _process(self, pcm: np.ndarray) -> None:
        self._on_state(State.PROCESSING)
        try:
            if not gates.passes_energy_gate(pcm, self._cfg.audio.energy_gate_rms):
                return
            t0 = self._clock()
            try:
                raw = gates.normalize(self._stt.transcribe(pcm))
            except SttError as e:
                log.warning("transcription failed: %s", e)
                self._save_failed_audio(pcm)
                self._on_notice(f"Transcription failed: {e}")
                self._on_state(State.ERROR)
                return
            if not raw:
                self._on_notice("Nothing transcribed")
                return
            final, cleaned = raw, False
            if self._cleaner is not None and gates.should_clean(
                raw, enabled=self._cleanup_enabled, min_words=self._cfg.cleanup.min_words
            ):
                out = self._try_clean(raw)
                if out is not None:
                    final, cleaned = out, True
            try:
                self._paster.paste(final)
            except PasteError as e:
                log.warning("paste failed: %s", e)
                self._on_notice("Paste failed — press ⌘V to paste manually")
            self._history.append(
                Record(
                    raw=raw,
                    final=final,
                    engine=self.engine_name,
                    cleaned=cleaned,
                    at=time.time(),
                    duration_ms=int((self._clock() - t0) * 1000),
                )
            )
        finally:
            self._on_state(State.IDLE)

    def _try_clean(self, raw: str) -> str | None:
        try:
            future = self._cleanup_pool.submit(self._cleaner.clean, raw)
            out = gates.normalize(future.result(timeout=self._cfg.cleanup.timeout_s))
        except Exception as e:
            log.warning("cleanup failed, using raw transcript: %s", e)
            return None
        if not out or not gates.length_ok(raw, out, self._cfg.cleanup.length_band):
            log.warning("cleanup output failed gates, using raw transcript")
            return None
        if not gates.language_consistent(raw, out):
            log.warning("cleanup translated the transcript, using raw")
            return None
        return out

    def _thread_runner(self, fn: Callable[[], None]) -> None:  # pragma: no cover - thread glue
        if self._work_queue is None:
            self._work_queue = queue.Queue()
            threading.Thread(target=self._drain, daemon=True, name="scribe-pipeline").start()
        self._work_queue.put(fn)

    def _drain(self) -> None:  # pragma: no cover - thread glue
        while True:
            fn = self._work_queue.get()
            try:
                fn()
            except Exception:
                log.exception("pipeline worker crashed on one dictation; continuing")

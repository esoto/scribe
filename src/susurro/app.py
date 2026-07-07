"""Composition root: builds every component and runs the menu bar app.

Models load in a background thread after the menu bar appears, so login is
instant; on load failure the app stays alive with the hotkey disabled
(spec §5: degrade, never die).
"""

from __future__ import annotations

import logging
import logging.handlers
import threading
import time
import wave
from pathlib import Path

import numpy as np

STATE_DIR = Path("~/.local/state/susurro").expanduser()

log = logging.getLogger(__name__)


def _setup_logging() -> None:  # pragma: no cover
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        STATE_DIR / "susurro.log", maxBytes=1_000_000, backupCount=7
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler])


def save_failed_audio(pcm: np.ndarray) -> None:  # pragma: no cover
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with wave.open(str(STATE_DIR / "last_failed.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes((np.clip(pcm, -1, 1) * 32767).astype(np.int16).tobytes())


def _play_sound(name: str) -> None:  # pragma: no cover
    from AppKit import NSSound

    sound = NSSound.soundNamed_(name)
    if sound is not None:
        sound.play()


def main() -> None:  # pragma: no cover - composition root, exercised manually
    _setup_logging()
    from susurro.config import DEFAULT_PATH, load_config
    from susurro.history import History
    from susurro.hotkey import HotkeyListener
    from susurro.menubar import SusurroMenuBar
    from susurro.paste import MacPasteboard, Paster, post_cmd_v, timer_schedule
    from susurro.pipeline import Pipeline, State
    from susurro.recorder import Recorder, RecorderError, default_stream_factory

    cfg, warnings = load_config(DEFAULT_PATH)
    for w in warnings:
        log.warning("config: %s", w)

    history = History(cfg.ui.history_size)
    recorder = Recorder(default_stream_factory, sample_rate=cfg.audio.sample_rate)
    paster = Paster(MacPasteboard(), post_cmd_v, timer_schedule, cfg.paste.clipboard_restore_delay_s)

    components: dict = {"pipeline": None, "ready": False, "load_error": None}

    menubar = SusurroMenuBar(
        on_engine=lambda name: _switch_engine(components, cfg, menubar, name),
        on_cleanup_toggle=lambda on: _toggle_cleanup(components, menubar, on),
        on_doctor=lambda: _run_doctor(menubar),
        on_reload=lambda: menubar.notify("Restart susurro to apply config changes"),
        history=history,
    )
    menubar.set_engine_checked(cfg.stt.engine)
    menubar.set_cleanup_checked(cfg.cleanup.enabled)

    def on_state(state: State) -> None:
        menubar.set_state(state)
        if state == State.RECORDING and cfg.ui.sounds:
            _play_sound("Pop")
        if state == State.ERROR and cfg.ui.sounds:
            _play_sound("Basso")

    def load_models() -> None:
        try:
            from susurro.cleanup.mlx_lm import MlxLmBackend
            from susurro.stt.parakeet import ParakeetEngine
            from susurro.stt.whisper import WhisperEngine

            log.info("loading models…")
            t0 = time.time()
            engine = (
                ParakeetEngine(cfg.stt.parakeet_model)
                if cfg.stt.engine == "parakeet"
                else WhisperEngine(cfg.stt.whisper_model)
            )
            cleaner = MlxLmBackend(cfg.cleanup.model) if cfg.cleanup.enabled else None
            components["pipeline"] = Pipeline(
                recorder=recorder,
                stt=engine,
                cleaner=cleaner,
                paster=paster,
                history=history,
                cfg=cfg,
                on_state=on_state,
                on_notice=menubar.notify,
                save_failed_audio=save_failed_audio,
            )
            components["ready"] = True
            log.info("models ready in %.1fs", time.time() - t0)
            menubar.set_state(State.IDLE)
        except Exception as e:
            components["load_error"] = str(e)
            log.exception("model load failed")
            menubar.set_state(State.ERROR)
            menubar.notify(f"Model load failed: {e}")

    def key_down() -> None:
        pipeline = components["pipeline"]
        if pipeline is None:
            return
        try:
            pipeline.key_down()
        except RecorderError as e:
            menubar.set_state(State.ERROR)
            menubar.notify(f"Microphone unavailable: {e}")

    def key_up() -> None:
        pipeline = components["pipeline"]
        if pipeline is not None:
            pipeline.key_up()

    try:
        recorder.start()
    except RecorderError as e:
        log.warning("mic stream not available at startup: %s", e)

    threading.Thread(target=load_models, daemon=True, name="susurro-model-load").start()

    listener = HotkeyListener(cfg.hotkey.key, key_down, key_up)
    try:
        listener.install()
    except PermissionError as e:
        log.error("%s", e)
        menubar.notify(str(e))

    menubar.run()


def _switch_engine(components, cfg, menubar, name: str) -> None:  # pragma: no cover
    pipeline = components["pipeline"]
    if pipeline is None:
        menubar.notify("Models still loading…")
        return

    def do_switch():
        try:
            if name == "whisper":
                from susurro.stt.whisper import WhisperEngine

                engine = WhisperEngine(cfg.stt.whisper_model)
            else:
                from susurro.stt.parakeet import ParakeetEngine

                engine = ParakeetEngine(cfg.stt.parakeet_model)
            pipeline.set_engine(engine, name=name)
            menubar.set_engine_checked(name)
        except Exception as e:
            menubar.notify(f"Engine switch failed: {e}")

    threading.Thread(target=do_switch, daemon=True).start()


def _toggle_cleanup(components, menubar, on: bool) -> None:  # pragma: no cover
    pipeline = components["pipeline"]
    if pipeline is not None:
        pipeline.set_cleanup_enabled(on)
        menubar.set_cleanup_checked(on)


def _run_doctor(menubar) -> None:  # pragma: no cover
    from susurro.doctor import default_probes, format_report, run_checks

    menubar.alert("susurro doctor", format_report(run_checks(default_probes())))

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

STATE_DIR = Path("~/.local/state/scribe").expanduser()

log = logging.getLogger(__name__)


def _setup_logging() -> None:  # pragma: no cover
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        STATE_DIR / "scribe.log", maxBytes=1_000_000, backupCount=7
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


def _request_microphone() -> None:  # pragma: no cover
    """Force the TCC microphone prompt for THIS process identity.

    Opening the stream via PortAudio does not reliably trigger the prompt;
    without the grant CoreAudio silently delivers all-zero samples, which
    the energy gate then (correctly) discards — no error anywhere.
    """
    from AVFoundation import AVCaptureDevice, AVMediaTypeAudio

    status = int(AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio))
    log.info("microphone authorization status: %d (3=authorized)", status)
    if status == 0:  # not determined — ask
        AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVMediaTypeAudio,
            lambda granted: log.info("microphone request result: granted=%s", bool(granted)),
        )
    elif status != 3:
        log.error(
            "microphone DENIED for this identity — enable Python in "
            "System Settings → Privacy & Security → Microphone"
        )


def _check_paste_access() -> None:  # pragma: no cover
    """Log (and request) permission to post ⌘V.

    Without it CGEventPost is SILENTLY swallowed — no error, no paste —
    so this is the only place the failure becomes visible.
    """
    import Quartz

    ok = bool(Quartz.CGPreflightPostEventAccess())
    log.info("post-event (paste) access: %s", ok)
    if not ok:
        Quartz.CGRequestPostEventAccess()
        log.error(
            "paste access MISSING — ⌘V will be silently dropped. Enable Python in "
            "System Settings → Privacy & Security → Accessibility, then restart scribe"
        )


def main() -> None:  # pragma: no cover - composition root, exercised manually
    import os

    # Privacy: force HF loaders to the local cache — zero network requests at
    # runtime. Export HF_HUB_OFFLINE=0 before launching to allow downloads
    # (only needed once when switching to a model that isn't cached yet).
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    _setup_logging()
    from scribe.config import DEFAULT_PATH, load_config
    from scribe.history import History
    from scribe.hotkey import HotkeyListener
    from scribe.menubar import ScribeMenuBar
    from scribe.paste import MacPasteboard, Paster, post_cmd_v, timer_schedule
    from scribe.pipeline import Pipeline, State
    from scribe.recorder import Recorder, RecorderError, default_stream_factory

    cfg, warnings = load_config(DEFAULT_PATH)
    for w in warnings:
        log.warning("config: %s", w)

    _request_microphone()
    _check_paste_access()

    history = History(cfg.ui.history_size)
    recorder = Recorder(default_stream_factory, sample_rate=cfg.audio.sample_rate)
    paster = Paster(MacPasteboard(), post_cmd_v, timer_schedule, cfg.paste.clipboard_restore_delay_s)

    components: dict = {"pipeline": None, "ready": False, "load_error": None}

    menubar = ScribeMenuBar(
        on_engine=lambda name: _switch_engine(components, cfg, menubar, name),
        on_cleanup_toggle=lambda on: _toggle_cleanup(components, menubar, on),
        on_doctor=lambda: _run_doctor(menubar),
        on_reload=lambda: menubar.notify("Restart scribe to apply config changes"),
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

    from scribe.mlx_thread import MlxThread, ThreadBoundCleaner, ThreadBoundStt

    mlx_thread = MlxThread()
    components["mlx"] = mlx_thread

    def load_models() -> None:
        try:
            from scribe.cleanup.mlx_lm import MlxLmBackend
            from scribe.stt.parakeet import ParakeetEngine
            from scribe.stt.whisper import WhisperEngine

            log.info("loading models…")
            t0 = time.time()
            engine = ThreadBoundStt(
                mlx_thread,
                (lambda: ParakeetEngine(cfg.stt.parakeet_model))
                if cfg.stt.engine == "parakeet"
                else (lambda: WhisperEngine(cfg.stt.whisper_model)),
            )
            cleaner = (
                ThreadBoundCleaner(mlx_thread, lambda: MlxLmBackend(cfg.cleanup.model))
                if cfg.cleanup.enabled
                else None
            )
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

    threading.Thread(target=load_models, daemon=True, name="scribe-model-load").start()

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
            from scribe.mlx_thread import ThreadBoundStt

            if name == "whisper":
                from scribe.stt.whisper import WhisperEngine

                engine = ThreadBoundStt(
                    components["mlx"], lambda: WhisperEngine(cfg.stt.whisper_model)
                )
            else:
                from scribe.stt.parakeet import ParakeetEngine

                engine = ThreadBoundStt(
                    components["mlx"], lambda: ParakeetEngine(cfg.stt.parakeet_model)
                )
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
    from scribe.doctor import default_probes, format_report, run_checks

    menubar.alert("scribe doctor", format_report(run_checks(default_probes())))

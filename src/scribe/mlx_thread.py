"""One dedicated thread for ALL MLX work, with lazy load/unload.

Empirical rule (verified 2026-07-07 on mlx 0.31/M2 Pro): model weights bind
to the GPU stream of the thread that loaded them, and that stream is not
visible from any other thread — cross-thread inference dies with
"There is no Stream(gpu, N) in current thread". So every model load and
every inference is marshaled onto this single thread.

Wrappers are lazy and unloadable: models load on first use (or explicit
preload) and can be dropped to reclaim Metal memory — weights are the
dominant footprint (~5.3 GB for all three models, measured via `footprint`).
"""

from __future__ import annotations

import gc
import logging
import queue
import threading
import time
from concurrent.futures import Future
from typing import Any, Callable

log = logging.getLogger(__name__)


def _release_mlx_memory() -> None:  # pragma: no cover - touches Metal
    try:
        import mlx.core as mx

        mx.clear_cache()
    except Exception:
        pass


class MlxThread:
    def __init__(self, name: str = "scribe-mlx"):
        self._queue: queue.Queue = queue.Queue()
        self._thread = threading.Thread(target=self._drain, daemon=True, name=name)
        self._thread.start()

    def submit(self, fn: Callable, *args: Any, **kwargs: Any) -> Future:
        future: Future = Future()
        self._queue.put((future, fn, args, kwargs))
        return future

    def call(self, fn: Callable, *args: Any, **kwargs: Any) -> Any:
        """Run fn on the MLX thread and block for its result."""
        return self.submit(fn, *args, **kwargs).result()

    def _drain(self) -> None:
        while True:
            future, fn, args, kwargs = self._queue.get()
            if not future.set_running_or_notify_cancel():
                continue
            try:
                future.set_result(fn(*args, **kwargs))
            except BaseException as e:
                future.set_exception(e)


class _ThreadBoundModel:
    """Lazy, unloadable model bound to the MLX thread.

    The wrapped model is only ever touched on the MLX thread, so no locks:
    _ensure/_drop run there exclusively.
    """

    def __init__(self, mlx: MlxThread, factory: Callable[[], Any], label: str,
                 release_memory: Callable[[], None] = _release_mlx_memory):
        self._mlx = mlx
        self._factory = factory
        self._label = label
        self._release_memory = release_memory
        self._model: Any = None

    def _ensure(self) -> Any:
        if self._model is None:
            log.info("loading %s…", self._label)
            t0 = time.time()
            self._model = self._factory()
            log.info("%s loaded in %.1fs", self._label, time.time() - t0)
        return self._model

    def _drop(self) -> None:
        if self._model is None:
            return
        self._model = None
        gc.collect()
        self._release_memory()
        log.info("%s unloaded", self._label)

    def preload(self) -> None:
        """Block until loaded (startup warm-up / engine switch)."""
        self._mlx.call(self._ensure)

    def preload_async(self) -> None:
        """Kick a load without waiting (hotkey-down warm-up after idle)."""
        self._mlx.submit(self._ensure)

    def unload(self) -> None:
        self._mlx.call(self._drop)

    @property
    def loaded(self) -> bool:
        return self._model is not None


class ThreadBoundStt(_ThreadBoundModel):
    """SttEngine that loads and runs the wrapped engine on the MLX thread."""

    def __init__(self, mlx: MlxThread, factory: Callable[[], Any], name: str, **kw):
        super().__init__(mlx, factory, label=f"stt:{name}", **kw)
        self.name = name

    def transcribe(self, pcm) -> str:
        return self._mlx.call(lambda: self._ensure().transcribe(pcm))


class ThreadBoundCleaner(_ThreadBoundModel):
    """CleanupBackend that loads and runs the wrapped backend on the MLX thread."""

    def __init__(self, mlx: MlxThread, factory: Callable[[], Any], **kw):
        super().__init__(mlx, factory, label="cleanup", **kw)

    def clean(self, text: str) -> str:
        return self._mlx.call(lambda: self._ensure().clean(text))

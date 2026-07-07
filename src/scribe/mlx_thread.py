"""One dedicated thread for ALL MLX work.

Empirical rule (verified 2026-07-07 on mlx 0.31/M2 Pro): model weights bind
to the GPU stream of the thread that loaded them, and that stream is not
visible from any other thread — cross-thread inference dies with
"There is no Stream(gpu, N) in current thread". So every model load and
every inference is marshaled onto this single thread.
"""

from __future__ import annotations

import queue
import threading
from concurrent.futures import Future
from typing import Any, Callable


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


class ThreadBoundStt:
    """SttEngine that constructs and runs the wrapped engine on the MLX thread."""

    def __init__(self, mlx: MlxThread, factory: Callable[[], Any]):
        self._mlx = mlx
        self._engine = mlx.call(factory)
        self.name = getattr(self._engine, "name", "unknown")

    def transcribe(self, pcm) -> str:
        return self._mlx.call(self._engine.transcribe, pcm)


class ThreadBoundCleaner:
    """CleanupBackend that constructs and runs the wrapped backend on the MLX thread."""

    def __init__(self, mlx: MlxThread, factory: Callable[[], Any]):
        self._mlx = mlx
        self._backend = mlx.call(factory)

    def clean(self, text: str) -> str:
        return self._mlx.call(self._backend.clean, text)

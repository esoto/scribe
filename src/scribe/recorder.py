"""Mic capture: pre-opened input stream + armed ring buffer.

The stream stays open from app start so the first syllable is never
clipped; arm() re-opens it if it died (sleep/wake, device unplug).
"""

from __future__ import annotations

import threading
from typing import Callable

import numpy as np


class RecorderError(Exception):
    """The input stream could not be (re)opened."""


class RingBuffer:
    def __init__(self, max_seconds: float, sample_rate: int):
        self._cap = int(max_seconds * sample_rate)
        self._chunks: list[np.ndarray] = []
        self._size = 0
        self._lock = threading.Lock()

    def append(self, chunk: np.ndarray) -> None:
        with self._lock:
            if self._size + chunk.shape[0] > self._cap:
                return
            self._chunks.append(chunk)
            self._size += chunk.shape[0]

    def drain(self) -> np.ndarray:
        with self._lock:
            chunks, self._chunks, self._size = self._chunks, [], 0
        if not chunks:
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(chunks)

    def clear(self) -> None:
        self.drain()


class Recorder:
    def __init__(self, stream_factory: Callable, sample_rate: int = 16000, max_seconds: float = 300):
        self._factory = stream_factory
        self._buffer = RingBuffer(max_seconds, sample_rate)
        self._armed = False
        self._stream = None

    def start(self) -> None:
        self.ensure_stream()

    def ensure_stream(self) -> None:
        if self._stream is not None and getattr(self._stream, "active", False):
            return
        if self._stream is not None:
            try:
                self._stream.close()
            except Exception:  # pragma: no cover - best-effort cleanup
                pass
        try:
            self._stream = self._factory(self._callback)
            self._stream.start()
        except Exception as e:
            self._stream = None
            raise RecorderError(f"could not open microphone stream: {e}") from e

    def arm(self) -> None:
        self.ensure_stream()
        self._buffer.clear()
        self._armed = True

    def disarm(self) -> np.ndarray:
        self._armed = False
        return self._buffer.drain()

    def _callback(self, indata: np.ndarray) -> None:
        if self._armed:
            mono = indata[:, 0] if indata.ndim == 2 else indata
            self._buffer.append(mono.copy())


def default_stream_factory(callback):  # pragma: no cover - real audio device
    import sounddevice as sd

    def _cb(indata, frames, time_info, status):
        callback(indata)

    return sd.InputStream(samplerate=16000, channels=1, dtype="float32", callback=_cb)

"""Bounded, thread-safe in-memory dictation history (privacy: never persisted)."""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass


@dataclass(frozen=True)
class Record:
    raw: str
    final: str
    engine: str
    cleaned: bool
    at: float
    duration_ms: int


class History:
    def __init__(self, maxlen: int):
        self._items: deque[Record] = deque(maxlen=maxlen)
        self._lock = threading.Lock()

    def append(self, record: Record) -> None:
        with self._lock:
            self._items.append(record)

    def items(self) -> list[Record]:
        with self._lock:
            return list(reversed(self._items))

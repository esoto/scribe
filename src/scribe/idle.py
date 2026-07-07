"""Idle tracking for on-demand model unloading (pure logic)."""

from __future__ import annotations


class IdleTracker:
    def __init__(self, unload_after_minutes: float):
        self._timeout_s = unload_after_minutes * 60
        self._last_activity: float | None = None

    @property
    def enabled(self) -> bool:
        return self._timeout_s > 0

    def touch(self, now: float) -> None:
        self._last_activity = now

    def due(self, now: float) -> bool:
        """True when models should unload: enabled, there was activity, and
        the timeout has elapsed. Never-used models are not unloaded (they are
        the startup warm-up; unloading them would cause a surprise cold start
        with no memory to reclaim)."""
        if not self.enabled or self._last_activity is None:
            return False
        return (now - self._last_activity) >= self._timeout_s

"""Clipboard paste with safe restore.

The universal dictation-app mechanism (clipboard + synthetic ⌘V) with the
two hard-won mitigations from the field: a configurable restore delay, and
skipping the restore entirely if the user copied something else meanwhile
(change-count check).
"""

from __future__ import annotations

from typing import Callable


class PasteError(Exception):
    """Paste could not be delivered; the text remains on the clipboard."""


class Paster:
    def __init__(
        self,
        pasteboard,
        post_cmd_v: Callable[[], None],
        schedule: Callable[[float, Callable[[], None]], None],
        restore_delay_s: float,
    ):
        self._pb = pasteboard
        self._post = post_cmd_v
        self._schedule = schedule
        self._delay = restore_delay_s

    def paste(self, text: str) -> None:
        saved = self._pb.get()
        self._pb.set(text)
        set_count = self._pb.change_count()
        try:
            self._post()
        except Exception as e:
            raise PasteError(str(e)) from e
        if saved is not None:
            self._schedule(self._delay, lambda: self._restore(saved, set_count))

    def _restore(self, saved: str, set_count: int) -> None:
        if self._pb.change_count() == set_count:
            self._pb.set(saved)


class MacPasteboard:  # pragma: no cover - AppKit adapter
    def __init__(self):
        from AppKit import NSPasteboard

        self._pb = NSPasteboard.generalPasteboard()

    def get(self) -> str | None:
        from AppKit import NSPasteboardTypeString

        value = self._pb.stringForType_(NSPasteboardTypeString)
        return str(value) if value is not None else None

    def set(self, value: str) -> None:
        from AppKit import NSPasteboardTypeString

        self._pb.clearContents()
        self._pb.setString_forType_(value, NSPasteboardTypeString)

    def change_count(self) -> int:
        return int(self._pb.changeCount())


def post_cmd_v() -> None:  # pragma: no cover - posts real key events
    import Quartz

    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, 9, down)
        Quartz.CGEventSetFlags(event, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def timer_schedule(delay_s: float, fn: Callable[[], None]) -> None:  # pragma: no cover
    import threading

    timer = threading.Timer(delay_s, fn)
    timer.daemon = True
    timer.start()

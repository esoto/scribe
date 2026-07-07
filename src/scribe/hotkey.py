"""Hold-to-talk key detection.

KeyStateMachine is pure (unit-tested); HotkeyListener wires it to a
CGEventTap and needs the Input Monitoring TCC grant.
"""

from __future__ import annotations

KEYCODES = {"right_command": 54, "right_option": 61, "f13": 105}
MODIFIER_MASKS = {54: 0x100000, 61: 0x80000}

_KEY_DOWN, _KEY_UP, _FLAGS_CHANGED = 10, 11, 12


class KeyStateMachine:
    def __init__(self, key: str):
        self._keycode = KEYCODES[key]
        self._mask = MODIFIER_MASKS.get(self._keycode)
        self._down = False

    def handle(self, event_type: int, keycode: int, flags: int) -> str | None:
        if keycode != self._keycode:
            return None
        if self._mask is not None:
            if event_type != _FLAGS_CHANGED:
                return None
            pressed = bool(flags & self._mask)
        else:
            if event_type == _KEY_DOWN:
                pressed = True
            elif event_type == _KEY_UP:
                pressed = False
            else:
                return None
        if pressed and not self._down:
            self._down = True
            return "down"
        if not pressed and self._down:
            self._down = False
            return "up"
        return None


class HotkeyListener:  # pragma: no cover - CGEventTap wiring
    def __init__(self, key: str, on_down, on_up):
        self._machine = KeyStateMachine(key)
        self._on_down, self._on_up = on_down, on_up
        self._tap = None

    def install(self) -> None:
        import Quartz

        mask = (
            Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged)
            | Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventKeyUp)
        )

        def cb(proxy, etype, event, refcon):
            keycode = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode)
            action = self._machine.handle(
                int(etype), int(keycode), int(Quartz.CGEventGetFlags(event))
            )
            if action == "down":
                self._on_down()
            elif action == "up":
                self._on_up()
            return event

        tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionListenOnly,
            mask,
            cb,
            None,
        )
        if tap is None:
            raise PermissionError("event tap denied — grant Input Monitoring in System Settings")
        source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
        Quartz.CFRunLoopAddSource(
            Quartz.CFRunLoopGetCurrent(), source, Quartz.kCFRunLoopCommonModes
        )
        Quartz.CGEventTapEnable(tap, True)
        # On macOS 26, creation SUCCEEDS without the Input Monitoring grant
        # and the tap is just silently left disabled — check, don't trust.
        if not Quartz.CGEventTapIsEnabled(tap):
            raise PermissionError(
                "event tap created but disabled — Input Monitoring grant is not "
                "reaching this process (from a terminal, grants attribute to the "
                "terminal app; via launchd, to Python.app). Run `make probe`."
            )
        self._tap = tap

"""Hotkey diagnostic probe (`make probe`).

Prints the state of every layer between macOS and the pipeline:
TCC grants -> event tap creation -> raw event delivery -> KeyStateMachine.
Run from a normal terminal, then HOLD AND RELEASE Right Command a few
times during the listen window.
"""

import time

import Quartz

from scribe.hotkey import KeyStateMachine

LISTEN_SECONDS = 12


def main() -> None:
    print("=== Layer 0: process identity ===")
    import os
    import subprocess

    exe = subprocess.run(
        ["ps", "-p", str(os.getpid()), "-o", "comm="], capture_output=True, text=True
    ).stdout.strip()
    print(f"running executable: {exe}")
    term = os.environ.get("TERM_PROGRAM")
    if term:
        print(f"NOTE: launched from {term} — macOS attributes TCC grants of terminal")
        print(f"      children to the TERMINAL app. Results below reflect {term}'s")
        print("      grants, NOT Python.app's. They do not predict launchd behavior.")

    print("\n=== Layer 1: TCC grants (as seen by this process) ===")
    print(f"input monitoring (CGPreflightListenEventAccess): {bool(Quartz.CGPreflightListenEventAccess())}")
    from ApplicationServices import AXIsProcessTrusted

    print(f"accessibility (AXIsProcessTrusted): {bool(AXIsProcessTrusted())}")

    print("\n=== Layer 2: event tap creation ===")
    machine = KeyStateMachine("right_command")
    events = {"count": 0}

    def cb(proxy, etype, event, refcon):
        keycode = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode)
        flags = int(Quartz.CGEventGetFlags(event))
        action = machine.handle(int(etype), int(keycode), flags)
        events["count"] += 1
        print(f"  event: type={int(etype)} keycode={keycode} flags={flags:#x} -> machine says: {action}")
        return event

    mask = (
        Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged)
        | Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
        | Quartz.CGEventMaskBit(Quartz.kCGEventKeyUp)
    )
    tap = Quartz.CGEventTapCreate(
        Quartz.kCGSessionEventTap,
        Quartz.kCGHeadInsertEventTap,
        Quartz.kCGEventTapOptionListenOnly,
        mask,
        cb,
        None,
    )
    print(f"tap created: {tap is not None}")
    if tap is None:
        print("=> Input Monitoring grant is NOT effective for this binary. Stopping.")
        return

    source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
    Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), source, Quartz.kCFRunLoopCommonModes)
    Quartz.CGEventTapEnable(tap, True)
    print(f"tap enabled: {bool(Quartz.CGEventTapIsEnabled(tap))}")

    print(f"\n=== Layer 3: listening {LISTEN_SECONDS}s — HOLD AND RELEASE RIGHT ⌘ NOW ===")
    deadline = time.time() + LISTEN_SECONDS
    while time.time() < deadline:
        Quartz.CFRunLoopRunInMode(Quartz.kCFRunLoopDefaultMode, 0.25, False)

    print(f"\n=== Summary: {events['count']} keyboard events received ===")
    if events["count"] == 0:
        print("=> Tap exists but NO events delivered: the Input Monitoring grant is not")
        print("   reaching this binary (wrong entry toggled, or macOS needs the entry")
        print("   removed and re-added). Layer 1 output above shows what macOS thinks.")
    else:
        print("=> Event delivery works. If the app still doesn't react, the bug is in")
        print("   the app wiring, not permissions.")


if __name__ == "__main__":
    main()

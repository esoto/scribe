"""Menu bar UI (rumps). Pure helpers up top; the rumps app is an adapter."""

from __future__ import annotations

from scribe.pipeline import State

_GLYPHS = {
    State.IDLE: "◦",
    State.RECORDING: "●",
    State.PROCESSING: "⋯",
    State.ERROR: "⚠",
}


def glyph_for(state: State) -> str:
    return _GLYPHS[state]


def truncate_label(text: str, n: int = 40) -> str:
    return text if len(text) <= n else text[: n - 1] + "…"


class ScribeMenuBar:  # pragma: no cover - rumps/AppKit adapter
    """Owns the rumps.App; delegates every decision to the wired callbacks."""

    def __init__(self, *, on_engine, on_cleanup_toggle, on_doctor, on_reload, history):
        import rumps

        self._rumps = rumps
        self._history = history
        self._on_engine = on_engine
        self._on_cleanup_toggle = on_cleanup_toggle
        self._app = rumps.App("scribe", title=glyph_for(State.IDLE), quit_button="Quit")

        self._engine_items = {
            "parakeet": rumps.MenuItem("Parakeet (fast)", callback=lambda _: on_engine("parakeet")),
            "whisper": rumps.MenuItem("Whisper (best Spanish)", callback=lambda _: on_engine("whisper")),
        }
        engine_menu = rumps.MenuItem("Engine")
        for item in self._engine_items.values():
            engine_menu.add(item)
        self._cleanup_item = rumps.MenuItem("Cleanup", callback=lambda item: on_cleanup_toggle(not item.state))
        self._history_menu = rumps.MenuItem("History")
        # Seed the submenu: rumps only creates the underlying NSMenu when an
        # item is added, and .clear() on a never-populated MenuItem crashes.
        self._history_menu.add(rumps.MenuItem("(empty)"))
        doctor_item = rumps.MenuItem("Doctor", callback=lambda _: on_doctor())
        reload_item = rumps.MenuItem("Reload config", callback=lambda _: on_reload())
        self._app.menu = [engine_menu, self._cleanup_item, self._history_menu, None, doctor_item, reload_item, None]

    def set_engine_checked(self, name: str) -> None:
        for key, item in self._engine_items.items():
            item.state = key == name

    def set_cleanup_checked(self, on: bool) -> None:
        self._cleanup_item.state = bool(on)

    def _on_main(self, fn) -> None:
        """Run fn on the main queue; log failures instead of dying.

        PyObjC converts an uncaught Python exception inside an ObjC block
        into an NSException that aborts the process — a UI glitch must
        never take dictation down.
        """
        from Foundation import NSOperationQueue

        def safe() -> None:
            try:
                fn()
            except Exception:
                import logging

                logging.getLogger(__name__).exception("menu bar update failed")

        NSOperationQueue.mainQueue().addOperationWithBlock_(safe)

    def set_state(self, state: State) -> None:
        def update() -> None:
            self._app.title = glyph_for(state)
            if state == State.PROCESSING:
                self.refresh_history()

        self._on_main(update)

    def refresh_history(self) -> None:
        self._history_menu.clear()
        records = self._history.items()
        if not records:
            self._history_menu.add(self._rumps.MenuItem("(empty)"))
            return
        for record in records:
            label = truncate_label(record.final)
            item = self._rumps.MenuItem(
                label, callback=(lambda text: lambda _: self._copy(text))(record.final)
            )
            self._history_menu.add(item)

    def _copy(self, text: str) -> None:
        from scribe.paste import MacPasteboard

        MacPasteboard().set(text)

    def notify(self, message: str) -> None:
        try:
            self._rumps.notification("scribe", "", message)
        except Exception:
            import logging

            logging.getLogger(__name__).warning("notification failed: %s", message)

    def alert(self, title: str, message: str) -> None:
        def show() -> None:
            self._rumps.alert(title=title, message=message)

        self._on_main(show)

    def run(self) -> None:
        self._app.run()

"""Clipboard paste with safe restore (full Paster arrives with the paste task)."""

from __future__ import annotations


class PasteError(Exception):
    """Paste could not be delivered; the text remains on the clipboard."""

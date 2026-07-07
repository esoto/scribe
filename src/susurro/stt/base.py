"""Speech-to-text engine protocol."""

from __future__ import annotations

from typing import Protocol

import numpy as np


class SttError(Exception):
    """Transcription failed; the pipeline saves the audio and degrades."""


class SttEngine(Protocol):
    name: str

    def transcribe(self, pcm: np.ndarray) -> str: ...

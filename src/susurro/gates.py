"""Pure decision helpers for the dictation pipeline.

The energy gate is the primary defense against Whisper's silence
hallucination — verified 2026-07-07: mlx-whisper produced "Thank you." on
near-silence with no_speech_prob=0.0, so probability filters alone are not
enough.
"""

from __future__ import annotations

import math

import numpy as np


def rms(pcm: np.ndarray) -> float:
    if pcm.size == 0:
        return 0.0
    return float(math.sqrt(float(np.mean(np.square(pcm, dtype=np.float64)))))


def passes_energy_gate(pcm: np.ndarray, threshold: float) -> bool:
    if pcm.size == 0:
        return False
    return rms(pcm) >= threshold


def should_clean(text: str, *, enabled: bool, min_words: int) -> bool:
    return enabled and len(text.split()) >= min_words


def length_ok(raw: str, cleaned: str, band: tuple[float, float]) -> bool:
    if not raw or not cleaned:
        return False
    ratio = len(cleaned) / len(raw)
    return band[0] <= ratio <= band[1]


def normalize(text: str) -> str:
    return " ".join(text.split())

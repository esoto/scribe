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


_EN_STOPWORDS = frozenset(
    "the a an is are was were be do does did to of on in at for with and or "
    "but this that it we you they should would could i".split()
)
_ES_STOPWORDS = frozenset(
    "el la los las un una es son está esta estaba ser hacer de en a para con "
    "y o pero este esto eso que se nosotros ustedes ellos debería yo según".split()
)


def _lang_score(text: str) -> int:
    """Positive = English-leaning, negative = Spanish-leaning, 0 = neutral."""
    words = text.lower().split()
    return sum(w in _EN_STOPWORDS for w in words) - sum(w in _ES_STOPWORDS for w in words)


def language_consistent(raw: str, cleaned: str) -> bool:
    """Reject cleanups that flipped the language (small-model translation bug,
    observed 2026-07-07 with Gemma 3 4B on Spanglish input). Neutral or
    ambiguous scores pass — only a confident flip fails."""
    raw_score, cleaned_score = _lang_score(raw), _lang_score(cleaned)
    return not (raw_score * cleaned_score < 0 and abs(raw_score - cleaned_score) >= 3)

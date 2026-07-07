"""mlx-whisper adapter — lazy-loaded fallback engine for Spanish-heavy work.

condition_on_previous_text=False and the no_speech filter reduce, but do not
eliminate, hallucination on non-speech audio; the pipeline's energy gate is
the primary defense (verified 2026-07-07: "Thank you." at no_speech_prob=0.0).
"""

from __future__ import annotations

import numpy as np

from susurro.stt.base import SttError


def join_segments(segments: list[dict], threshold: float = 0.6) -> str:
    kept = [
        s["text"].strip()
        for s in segments
        if s.get("no_speech_prob", 0.0) <= threshold and s["text"].strip()
    ]
    return " ".join(kept)


class WhisperEngine:
    name = "whisper"

    def __init__(self, model_repo: str):
        self._repo = model_repo

    def transcribe(self, pcm: np.ndarray) -> str:  # pragma: no cover - MLX inference
        try:
            import mlx_whisper

            result = mlx_whisper.transcribe(
                pcm, path_or_hf_repo=self._repo, condition_on_previous_text=False
            )
            return join_segments(result.get("segments", []))
        except Exception as e:
            raise SttError(str(e)) from e

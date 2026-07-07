"""Parakeet TDT v3 adapter — the resident default engine.

Uses the array path verified 2026-07-07: get_logmel + generate, no temp
files, ~220 ms warm for a 10 s utterance on the M2 Pro.
"""

from __future__ import annotations

import numpy as np

from susurro.stt.base import SttError


class ParakeetEngine:
    name = "parakeet"

    def __init__(self, model_repo: str):  # pragma: no cover - loads MLX model
        from parakeet_mlx import from_pretrained

        self._model = from_pretrained(model_repo)

    def transcribe(self, pcm: np.ndarray) -> str:  # pragma: no cover - MLX inference
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        try:
            mel = get_logmel(mx.array(pcm), self._model.preprocessor_config)
            results = self._model.generate(mel)
            return " ".join(r.text.strip() for r in results if r.text.strip())
        except Exception as e:
            raise SttError(str(e)) from e

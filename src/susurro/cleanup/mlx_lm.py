"""Gemma 3 4B cleanup backend via mlx-lm (temp 0, validated prompt)."""

from __future__ import annotations

from susurro.cleanup.base import CleanupError, build_messages, max_tokens_for


class MlxLmBackend:
    def __init__(self, model_repo: str):  # pragma: no cover - loads MLX model
        from mlx_lm import load

        self._model, self._tok = load(model_repo)

    def clean(self, text: str) -> str:  # pragma: no cover - MLX inference
        try:
            from mlx_lm import generate
            from mlx_lm.sample_utils import make_sampler

            prompt = self._tok.apply_chat_template(
                build_messages(text), add_generation_prompt=True
            )
            n_in = len(self._tok.encode(text))
            return generate(
                self._model,
                self._tok,
                prompt=prompt,
                max_tokens=max_tokens_for(n_in),
                sampler=make_sampler(temp=0.0),
            )
        except Exception as e:
            raise CleanupError(str(e)) from e

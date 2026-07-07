import wave
from pathlib import Path

import numpy as np
import pytest

FIXTURES = Path(__file__).parent / "fixtures"


def load_pcm(name: str) -> np.ndarray:
    with wave.open(str(FIXTURES / name)) as w:
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


@pytest.fixture(scope="session")
def parakeet():
    from scribe.stt.parakeet import ParakeetEngine

    return ParakeetEngine("mlx-community/parakeet-tdt-0.6b-v3")


@pytest.fixture(scope="session")
def whisper():
    from scribe.stt.whisper import WhisperEngine

    return WhisperEngine("mlx-community/whisper-large-v3-turbo")


@pytest.fixture(scope="session")
def gemma():
    from scribe.cleanup.mlx_lm import MlxLmBackend

    return MlxLmBackend("mlx-community/gemma-3-4b-it-qat-4bit")

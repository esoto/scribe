import threading

import pytest

from scribe.mlx_thread import MlxThread, ThreadBoundCleaner, ThreadBoundStt


def test_call_runs_on_dedicated_thread_and_returns():
    mlx = MlxThread(name="test-mlx")
    seen = mlx.call(lambda: threading.current_thread().name)
    assert seen == "test-mlx"


def test_all_calls_share_one_thread():
    mlx = MlxThread(name="test-mlx-2")
    names = {mlx.call(lambda: threading.current_thread().name) for _ in range(5)}
    assert names == {"test-mlx-2"}


def test_exceptions_propagate_to_caller():
    mlx = MlxThread(name="test-mlx-3")

    def boom():
        raise RuntimeError("stream gone")

    with pytest.raises(RuntimeError, match="stream gone"):
        mlx.call(boom)
    assert mlx.call(lambda: 42) == 42  # thread survives the exception


class Engine:
    name = "fake"

    def __init__(self):
        self.load_thread = threading.current_thread().name

    def transcribe(self, pcm):
        return f"{self.load_thread}|{threading.current_thread().name}"

    def clean(self, text):
        return f"{self.load_thread}|{threading.current_thread().name}"


def test_thread_bound_stt_loads_and_infers_on_same_thread():
    mlx = MlxThread(name="test-mlx-4")
    stt = ThreadBoundStt(mlx, Engine)
    load_thread, infer_thread = stt.transcribe(None).split("|")
    assert load_thread == infer_thread == "test-mlx-4"
    assert stt.name == "fake"


def test_thread_bound_cleaner_loads_and_cleans_on_same_thread():
    mlx = MlxThread(name="test-mlx-5")
    cleaner = ThreadBoundCleaner(mlx, Engine)
    load_thread, clean_thread = cleaner.clean("x").split("|")
    assert load_thread == clean_thread == "test-mlx-5"

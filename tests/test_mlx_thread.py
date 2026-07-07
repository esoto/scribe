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
    assert mlx.call(lambda: 42) == 42


class Engine:
    instances = 0

    def __init__(self):
        Engine.instances += 1
        self.load_thread = threading.current_thread().name

    def transcribe(self, pcm):
        return f"{self.load_thread}|{threading.current_thread().name}"

    def clean(self, text):
        return f"{self.load_thread}|{threading.current_thread().name}"


def make_stt(name="test-mlx-4"):
    Engine.instances = 0
    mlx = MlxThread(name=name)
    return ThreadBoundStt(mlx, Engine, name="fake", release_memory=lambda: None)


def test_lazy_load_then_infer_on_same_thread():
    stt = make_stt()
    assert not stt.loaded and Engine.instances == 0
    load_thread, infer_thread = stt.transcribe(None).split("|")
    assert load_thread == infer_thread == "test-mlx-4"
    assert stt.loaded and Engine.instances == 1
    assert stt.name == "fake"


def test_repeated_calls_load_once():
    stt = make_stt("test-mlx-5")
    stt.transcribe(None)
    stt.transcribe(None)
    assert Engine.instances == 1


def test_unload_frees_and_reload_works():
    stt = make_stt("test-mlx-6")
    stt.transcribe(None)
    stt.unload()
    assert not stt.loaded
    load_thread, infer_thread = stt.transcribe(None).split("|")
    assert load_thread == infer_thread == "test-mlx-6"
    assert Engine.instances == 2


def test_unload_when_never_loaded_is_noop():
    stt = make_stt("test-mlx-7")
    stt.unload()
    assert Engine.instances == 0


def test_preload_blocks_until_loaded():
    stt = make_stt("test-mlx-8")
    stt.preload()
    assert stt.loaded and Engine.instances == 1


def test_preload_async_eventually_loads():
    stt = make_stt("test-mlx-9")
    stt.preload_async()
    stt.transcribe(None)  # queued behind the async load on the same thread
    assert Engine.instances == 1


def test_cleaner_same_thread_and_unloadable():
    Engine.instances = 0
    mlx = MlxThread(name="test-mlx-10")
    cleaner = ThreadBoundCleaner(mlx, Engine, release_memory=lambda: None)
    load_thread, clean_thread = cleaner.clean("x").split("|")
    assert load_thread == clean_thread == "test-mlx-10"
    cleaner.unload()
    assert not cleaner.loaded

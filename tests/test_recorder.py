import numpy as np
import pytest

from scribe.recorder import Recorder, RecorderError, RingBuffer


def chunk(v, n=160):
    return np.full((n, 1), v, dtype=np.float32)


class FakeStream:
    def __init__(self, fail=False):
        self.active, self.fail = False, fail

    def start(self):
        if self.fail:
            raise OSError("no device")
        self.active = True

    def stop(self):
        self.active = False

    def close(self):
        self.active = False


def test_ring_buffer_drain_concatenates():
    rb = RingBuffer(max_seconds=1, sample_rate=160)
    rb.append(np.ones(80, dtype=np.float32))
    rb.append(np.zeros(80, dtype=np.float32))
    out = rb.drain()
    assert out.shape == (160,) and out[0] == 1.0 and out[-1] == 0.0
    assert rb.drain().shape == (0,)


def test_ring_buffer_caps_capacity():
    rb = RingBuffer(max_seconds=1, sample_rate=160)
    for _ in range(5):
        rb.append(np.ones(80, dtype=np.float32))
    assert rb.drain().shape[0] <= 160


def test_recorder_captures_only_while_armed():
    streams = []

    def factory(cb):
        streams.append(FakeStream())
        factory.cb = cb
        return streams[-1]

    r = Recorder(factory)
    r.start()
    factory.cb(chunk(0.5))
    r.arm()
    factory.cb(chunk(1.0))
    pcm = r.disarm()
    factory.cb(chunk(0.7))
    assert np.all(pcm == 1.0) and pcm.ndim == 1


def test_arm_reopens_dead_stream():
    streams = []

    def factory(cb):
        streams.append(FakeStream())
        return streams[-1]

    r = Recorder(factory)
    r.start()
    streams[0].active = False
    r.arm()
    assert len(streams) == 2 and streams[1].active


def test_ensure_stream_raises_when_reopen_fails():
    def factory(cb):
        return FakeStream(fail=True)

    r = Recorder(factory)
    with pytest.raises(RecorderError):
        r.ensure_stream()

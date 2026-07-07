import time

import numpy as np

VOICED = np.full(16000, 0.1, dtype=np.float32)
SILENT = np.zeros(16000, dtype=np.float32)


class FakeRecorder:
    def __init__(self, pcm=VOICED):
        self.pcm, self.armed = pcm, False

    def arm(self):
        self.armed = True

    def disarm(self):
        self.armed = False
        return self.pcm


class FakeStt:
    name = "parakeet"

    def __init__(self, text="so um hello there world", err=None):
        self.text, self.err, self.calls = text, err, 0

    def transcribe(self, pcm):
        self.calls += 1
        if self.err:
            raise self.err
        return self.text


class FakeCleaner:
    def __init__(self, out="hello there world", err=None, delay=0.0):
        self.out, self.err, self.delay, self.calls = out, err, delay, 0

    def clean(self, text):
        self.calls += 1
        if self.delay:
            time.sleep(self.delay)
        if self.err:
            raise self.err
        return self.out


class FakePaster:
    def __init__(self, err=None):
        self.err, self.pasted = err, []

    def paste(self, text):
        if self.err:
            raise self.err
        self.pasted.append(text)


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

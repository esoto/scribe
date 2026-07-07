import pytest

from susurro.paste import Paster, PasteError


class FakePb:
    def __init__(self, initial="old stuff"):
        self._v, self._count = initial, 1

    def get(self):
        return self._v

    def set(self, v):
        self._v, self._count = v, self._count + 1

    def change_count(self):
        return self._count


class Sched:
    def __init__(self):
        self.jobs = []

    def __call__(self, delay, fn):
        self.jobs.append((delay, fn))

    def fire(self):
        for _, fn in self.jobs:
            fn()


def test_paste_sets_posts_and_restores():
    pb, sched, posts = FakePb(), Sched(), []
    p = Paster(pb, lambda: posts.append(1), sched, 2.0)
    p.paste("nuevo texto")
    assert pb.get() == "nuevo texto" and posts == [1]
    assert sched.jobs[0][0] == 2.0
    sched.fire()
    assert pb.get() == "old stuff"


def test_restore_skipped_if_user_copied_meanwhile():
    pb, sched = FakePb(), Sched()
    p = Paster(pb, lambda: None, sched, 2.0)
    p.paste("nuevo")
    pb.set("user copied this")
    sched.fire()
    assert pb.get() == "user copied this"


def test_empty_clipboard_no_restore_scheduled():
    pb, sched = FakePb(initial=None), Sched()
    Paster(pb, lambda: None, sched, 2.0).paste("hola")
    assert sched.jobs == []


def test_post_failure_raises_and_keeps_text_on_clipboard():
    pb, sched = FakePb(), Sched()

    def boom():
        raise OSError("secure input")

    p = Paster(pb, boom, sched, 2.0)
    with pytest.raises(PasteError):
        p.paste("texto")
    assert pb.get() == "texto" and sched.jobs == []

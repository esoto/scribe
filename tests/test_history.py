from scribe.history import History, Record


def rec(i):
    return Record(raw=f"r{i}", final=f"f{i}", engine="parakeet", cleaned=True, at=float(i), duration_ms=10)


def test_newest_first_and_bounded():
    h = History(maxlen=3)
    for i in range(5):
        h.append(rec(i))
    assert [r.raw for r in h.items()] == ["r4", "r3", "r2"]


def test_empty():
    assert History(maxlen=3).items() == []

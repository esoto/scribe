from scribe.idle import IdleTracker


def test_disabled_when_zero():
    t = IdleTracker(0)
    assert not t.enabled
    t.touch(100.0)
    assert not t.due(100000.0)


def test_not_due_before_any_activity():
    t = IdleTracker(15)
    assert not t.due(100000.0)


def test_due_after_timeout():
    t = IdleTracker(15)
    t.touch(1000.0)
    assert not t.due(1000.0 + 14 * 60)
    assert t.due(1000.0 + 15 * 60)


def test_activity_resets_timer():
    t = IdleTracker(15)
    t.touch(0.0)
    t.touch(10 * 60.0)
    assert not t.due(20 * 60.0)
    assert t.due(25 * 60.0)

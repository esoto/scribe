from susurro.hotkey import KEYCODES, KeyStateMachine

CMD = 0x100000


def test_keycode_table():
    assert KEYCODES == {"right_command": 54, "right_option": 61, "f13": 105}


def test_right_command_down_up():
    m = KeyStateMachine("right_command")
    assert m.handle(12, 54, CMD) == "down"
    assert m.handle(12, 54, 0) == "up"


def test_other_keycode_ignored():
    m = KeyStateMachine("right_command")
    assert m.handle(12, 55, CMD) is None
    assert m.handle(12, 61, 0x80000) is None


def test_duplicate_flags_events_ignored():
    m = KeyStateMachine("right_command")
    assert m.handle(12, 54, CMD) == "down"
    assert m.handle(12, 54, CMD) is None
    assert m.handle(12, 54, 0) == "up"
    assert m.handle(12, 54, 0) is None


def test_f13_uses_keydown_keyup():
    m = KeyStateMachine("f13")
    assert m.handle(10, 105, 0) == "down"
    assert m.handle(11, 105, 0) == "up"
    assert m.handle(12, 105, 0) is None


def test_right_option():
    m = KeyStateMachine("right_option")
    assert m.handle(12, 61, 0x80000) == "down"
    assert m.handle(12, 61, 0) == "up"


def test_modifier_key_ignores_keydown_events():
    m = KeyStateMachine("right_command")
    assert m.handle(10, 54, CMD) is None

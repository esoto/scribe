from scribe.menubar import glyph_for, truncate_label
from scribe.pipeline import State


def test_glyphs():
    assert glyph_for(State.IDLE) == "◦"
    assert glyph_for(State.RECORDING) == "●"
    assert glyph_for(State.PROCESSING) == "⋯"
    assert glyph_for(State.ERROR) == "⚠"


def test_truncate():
    assert truncate_label("corto") == "corto"
    long = "x" * 60
    assert truncate_label(long) == "x" * 39 + "…"

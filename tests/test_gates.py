import numpy as np

from susurro.gates import length_ok, normalize, passes_energy_gate, rms, should_clean


def test_rms_silence_vs_tone():
    silent = np.zeros(1600, dtype=np.float32)
    tone = (0.1 * np.sin(np.linspace(0, 100, 1600))).astype(np.float32)
    assert rms(silent) == 0.0
    assert rms(tone) > 0.05


def test_energy_gate():
    assert not passes_energy_gate(np.zeros(100, dtype=np.float32), 0.005)
    assert not passes_energy_gate(np.zeros(0, dtype=np.float32), 0.005)
    assert passes_energy_gate(np.full(100, 0.1, dtype=np.float32), 0.005)


def test_should_clean():
    assert should_clean("one two three four", enabled=True, min_words=4)
    assert not should_clean("one two three", enabled=True, min_words=4)
    assert not should_clean("one two three four", enabled=False, min_words=4)


def test_length_ok():
    band = (0.5, 1.3)
    assert length_ok("a" * 100, "a" * 80, band)
    assert not length_ok("a" * 100, "a" * 20, band)
    assert not length_ok("a" * 100, "a" * 200, band)
    assert not length_ok("hello", "", band)


def test_normalize_preserves_spanish():
    assert normalize("  el  martes,\n antes del mediodía.  ") == "el martes, antes del mediodía."


def test_rms_empty_is_zero():
    assert rms(np.zeros(0, dtype=np.float32)) == 0.0

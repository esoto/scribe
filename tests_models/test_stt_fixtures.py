"""Tier-2: real engines against the committed benchmark fixtures.

Catches model/package regressions on version bumps (spec §7).
"""

import numpy as np
import pytest

from susurro.gates import passes_energy_gate
from tests_models.conftest import load_pcm

pytestmark = pytest.mark.models


def test_parakeet_english(parakeet):
    text = parakeet.transcribe(load_pcm("en.wav")).lower()
    assert "wednesday" in text and "marcos" in text


def test_parakeet_spanish(parakeet):
    text = parakeet.transcribe(load_pcm("es.wav")).lower()
    assert "deberíamos" in text and "mediodía" in text


def test_parakeet_silence_is_empty(parakeet):
    assert parakeet.transcribe(load_pcm("silence.wav")).strip() == ""


def test_whisper_english(whisper):
    text = whisper.transcribe(load_pcm("en.wav")).lower()
    assert "wednesday" in text and "marcos" in text


def test_whisper_spanish(whisper):
    text = whisper.transcribe(load_pcm("es.wav")).lower()
    assert "deberíamos" in text and "mediodía" in text


def test_energy_gate_blocks_silence_before_whisper():
    """Documents the hallucination defense: whisper may hallucinate on
    silence (observed: "Thank you." at no_speech_prob=0.0), but the
    pipeline's energy gate discards this capture before any engine runs."""
    pcm = load_pcm("silence.wav")
    assert not passes_energy_gate(pcm, 0.005)


def test_voiced_fixtures_pass_energy_gate():
    for name in ("en.wav", "es.wav", "mixed.wav"):
        assert passes_energy_gate(load_pcm(name), 0.005), name

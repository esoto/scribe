"""Tier-2: the three validated cleanup probes against real Gemma."""

import pytest

pytestmark = pytest.mark.models


def test_resolves_correction_to_wednesday(gemma):
    out = gemma.clean(
        "so um I think we should uh we should probably move the the meeting "
        "to Tuesday no wait Wednesday afternoon and uh tell tell marcos about it"
    ).lower()
    assert "wednesday" in out and "tuesday" not in out
    assert " um" not in out and " uh" not in out


def test_spanish_muletillas_and_accents(gemma):
    out = gemma.clean(
        "este bueno yo creo que deberiamos eh deberiamos mandar el reporte el "
        "lunes no mejor el martes en la mañana o sea antes del mediodia"
    ).lower()
    assert "martes" in out and "lunes" not in out
    # "o sea" may legitimately survive as a connector ("that is") — only the
    # hard fillers are required gone.
    assert "este bueno" not in out and " eh " not in out
    assert "mediodía" in out


def test_instruction_looking_text_is_not_executed(gemma):
    out = gemma.clean(
        "okay so add a uh a rescue block to the import job that um that retries "
        "three times with exponential backoff and then uh logs to sentry"
    )
    low = out.lower()
    assert "rescue block" in low and "sentry" in low
    assert "```" not in out and "import requests" not in low

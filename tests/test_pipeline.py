import dataclasses
from pathlib import Path

import numpy as np

from scribe.config import load_config
from scribe.history import History
from scribe.paste import PasteError
from scribe.pipeline import Pipeline, State
from scribe.stt.base import SttError
from tests.fakes import SILENT, FakeClock, FakeCleaner, FakePaster, FakeRecorder, FakeStt


def make(**kw):
    cfg = kw.pop("cfg", load_config(Path("/nonexistent"))[0])
    clock = FakeClock()
    states, notices, saved = [], [], []
    p = Pipeline(
        recorder=kw.pop("recorder", FakeRecorder()),
        stt=kw.pop("stt", FakeStt()),
        cleaner=kw.pop("cleaner", FakeCleaner()),
        paster=kw.pop("paster", FakePaster()),
        history=kw.pop("history", History(10)),
        cfg=cfg,
        clock=clock,
        runner=lambda f: f(),
        on_state=states.append,
        on_notice=notices.append,
        save_failed_audio=saved.append,
        **kw,
    )
    return p, clock, states, notices, saved


def dictate(p, clock, hold=1.0):
    p.key_down()
    clock.t += hold
    p.key_up()


def test_happy_path_cleans_and_pastes():
    paster, hist = FakePaster(), History(10)
    p, clock, states, _, _ = make(paster=paster, history=hist)
    dictate(p, clock)
    assert paster.pasted == ["hello there world"]
    assert hist.items()[0].raw == "so um hello there world"
    assert hist.items()[0].cleaned is True
    assert states[-1] == State.IDLE and State.RECORDING in states and State.PROCESSING in states


def test_sub_threshold_tap_discarded():
    stt = FakeStt()
    p, clock, *_ = make(stt=stt)
    dictate(p, clock, hold=0.1)
    assert stt.calls == 0


def test_energy_gate_discards_silence():
    stt = FakeStt()
    p, clock, *_ = make(recorder=FakeRecorder(pcm=SILENT), stt=stt)
    dictate(p, clock)
    assert stt.calls == 0


def test_short_utterance_skips_cleanup():
    cleaner, paster = FakeCleaner(), FakePaster()
    p, clock, *_ = make(stt=FakeStt(text="just three words"), cleaner=cleaner, paster=paster)
    dictate(p, clock)
    assert cleaner.calls == 0
    assert paster.pasted == ["just three words"]


def test_cleanup_disabled_skips():
    cleaner, paster = FakeCleaner(), FakePaster()
    p, clock, *_ = make(cleaner=cleaner, paster=paster)
    p.set_cleanup_enabled(False)
    dictate(p, clock)
    assert cleaner.calls == 0 and paster.pasted == ["so um hello there world"]


def test_cleanup_error_falls_back_to_raw():
    paster = FakePaster()
    p, clock, *_ = make(cleaner=FakeCleaner(err=RuntimeError("boom")), paster=paster)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]


def test_cleanup_timeout_falls_back_to_raw():
    paster = FakePaster()
    cfg = load_config(Path("/nonexistent"))[0]
    cfg = dataclasses.replace(cfg, cleanup=dataclasses.replace(cfg.cleanup, timeout_s=0.01))
    p, clock, *_ = make(cleaner=FakeCleaner(delay=0.2), paster=paster, cfg=cfg)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]


def test_cleanup_length_gate_falls_back():
    paster = FakePaster()
    p, clock, *_ = make(cleaner=FakeCleaner(out="x"), paster=paster)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]


def test_cleanup_empty_falls_back():
    paster = FakePaster()
    p, clock, *_ = make(cleaner=FakeCleaner(out="   "), paster=paster)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]


def test_no_cleaner_pastes_raw():
    paster = FakePaster()
    p, clock, *_ = make(cleaner=None, paster=paster)
    dictate(p, clock)
    assert paster.pasted == ["so um hello there world"]


def test_stt_error_saves_audio_and_notifies():
    paster = FakePaster()
    p, clock, states, notices, saved = make(stt=FakeStt(err=SttError("dead")), paster=paster)
    dictate(p, clock)
    assert paster.pasted == []
    assert len(saved) == 1 and isinstance(saved[0], np.ndarray)
    assert notices and State.ERROR in states


def test_stt_empty_discards_with_notice():
    paster = FakePaster()
    p, clock, _, notices, _ = make(stt=FakeStt(text="  "), paster=paster)
    dictate(p, clock)
    assert paster.pasted == [] and notices


def test_paste_error_notifies_manual_paste():
    hist = History(10)
    p, clock, _, notices, _ = make(paster=FakePaster(err=PasteError("secure input")), history=hist)
    dictate(p, clock)
    assert any("⌘V" in n for n in notices)
    assert len(hist.items()) == 1


def test_history_records_engine_and_raw_final():
    hist = History(10)
    p, clock, *_ = make(history=hist)
    dictate(p, clock)
    r = hist.items()[0]
    assert r.engine == "parakeet" and r.final == "hello there world"


def test_engine_swap():
    paster = FakePaster()
    p, clock, *_ = make(paster=paster)
    p.set_engine(FakeStt(text="desde whisper aquí cuatro"), name="whisper")
    dictate(p, clock)
    assert p.engine_name == "whisper"
    assert len(paster.pasted) == 1


def test_two_dictations_fifo():
    paster = FakePaster()
    p, clock, *_ = make(paster=paster)
    dictate(p, clock)
    dictate(p, clock)
    assert len(paster.pasted) == 2


def test_cleanup_translation_falls_back_to_raw():
    paster = FakePaster()
    p, clock, *_ = make(
        stt=FakeStt(text="digamos que el deploy se hace el viernes antes de las cinco"),
        cleaner=FakeCleaner(out="The deploy is done on Friday before five o'clock."),
        paster=paster,
    )
    dictate(p, clock)
    assert paster.pasted == ["digamos que el deploy se hace el viernes antes de las cinco"]

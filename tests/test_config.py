from susurro.config import load_config


def test_defaults_when_missing(tmp_path):
    cfg, warns = load_config(tmp_path / "nope.toml")
    assert cfg.hotkey.key == "right_command"
    assert cfg.hotkey.hold_threshold_s == 0.3
    assert cfg.stt.engine == "parakeet"
    assert cfg.cleanup.enabled is True
    assert cfg.cleanup.length_band == (0.5, 1.3)
    assert cfg.paste.clipboard_restore_delay_s == 2.0
    assert cfg.audio.energy_gate_rms == 0.005
    assert cfg.ui.history_size == 10
    assert warns == []


def test_full_parse(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text('[hotkey]\nkey="f13"\nhold_threshold_s=0.5\n[cleanup]\nenabled=false\nmin_words=2\n')
    cfg, warns = load_config(p)
    assert cfg.hotkey.key == "f13" and cfg.hotkey.hold_threshold_s == 0.5
    assert cfg.cleanup.enabled is False and cfg.cleanup.min_words == 2
    assert warns == []


def test_invalid_field_falls_back_with_warning(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text('[hotkey]\nkey="caps_lock"\n[cleanup]\nlength_band=[2.0,0.1]\n')
    cfg, warns = load_config(p)
    assert cfg.hotkey.key == "right_command"
    assert cfg.cleanup.length_band == (0.5, 1.3)
    assert len(warns) == 2


def test_unparseable_toml_all_defaults(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text("not [ toml")
    cfg, warns = load_config(p)
    assert cfg == load_config(tmp_path / "missing.toml")[0]
    assert warns


def test_unknown_keys_ignored(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text("[hotkey]\nbanana=1\n")
    cfg, warns = load_config(p)
    assert cfg.hotkey.key == "right_command"
    assert warns == []


def test_wrong_type_warns(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text('[audio]\nenergy_gate_rms="loud"\n')
    cfg, warns = load_config(p)
    assert cfg.audio.energy_gate_rms == 0.005
    assert len(warns) == 1


def test_engine_validated(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text('[stt]\nengine="siri"\n')
    cfg, warns = load_config(p)
    assert cfg.stt.engine == "parakeet"
    assert len(warns) == 1


def test_section_not_a_table_warns(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text("hotkey = 5\n")
    cfg, warns = load_config(p)
    assert cfg.hotkey.key == "right_command"
    assert any("expected a table" in w for w in warns)


def test_positive_validator_used(tmp_path):
    p = tmp_path / "c.toml"
    p.write_text("[cleanup]\ntimeout_s = -1\n[ui]\nhistory_size = 0\n")
    cfg, warns = load_config(p)
    assert cfg.cleanup.timeout_s == 6.0 and cfg.ui.history_size == 10
    assert len(warns) == 2

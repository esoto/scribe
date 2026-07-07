from scribe.doctor import Check, format_report, run_checks


def test_run_checks_ok_and_fail_and_crash():
    probes = {
        "mic": (lambda: True, "hint-mic"),
        "ax": (lambda: False, "hint-ax"),
        "boom": (lambda: 1 / 0, "hint-boom"),
    }
    checks = run_checks(probes)
    assert [c.ok for c in checks] == [True, False, False]
    assert "hint-boom" in checks[2].hint


def test_format_report():
    out = format_report(
        [Check("mic", True, "h1"), Check("ax", False, "System Settings → Accessibility")]
    )
    assert "✓ mic" in out and "✗ ax" in out and "Accessibility" in out


def test_grant_target_prefers_python_app_bundle(tmp_path):
    from scribe.doctor import _grant_target_for

    real = tmp_path / "Frameworks" / "Python.framework" / "Versions" / "3.14" / "bin" / "python3.14"
    real.parent.mkdir(parents=True)
    real.touch()
    app = real.parent.parent / "Resources" / "Python.app"
    app.mkdir(parents=True)
    assert _grant_target_for(str(real)) == str(app)


def test_grant_target_falls_back_to_binary(tmp_path):
    from scribe.doctor import _grant_target_for

    real = tmp_path / "bin" / "python3.14"
    real.parent.mkdir(parents=True)
    real.touch()
    assert _grant_target_for(str(real)) == str(real)

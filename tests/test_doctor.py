from susurro.doctor import Check, format_report, run_checks


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

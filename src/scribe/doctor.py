"""Permission and model health checks (`make doctor` / menu item).

macOS TCC binds grants to the interpreter binary — after rebuilding .venv
you must re-grant all three permissions.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    hint: str


def run_checks(probes: dict[str, tuple[Callable[[], bool], str]]) -> list[Check]:
    checks = []
    for name, (probe, hint) in probes.items():
        try:
            ok = bool(probe())
        except Exception as e:
            ok, hint = False, f"{hint} (probe error: {e})"
        checks.append(Check(name, ok, hint))
    return checks


def format_report(checks: list[Check]) -> str:
    lines = []
    for c in checks:
        mark = "✓" if c.ok else "✗"
        lines.append(f"{mark} {c.name}")
        if not c.ok:
            lines.append(f"  → {c.hint}")
    return "\n".join(lines)


def _grant_target_for(real_executable: str) -> str:
    """The path macOS actually attributes TCC grants to.

    Framework Python builds re-exec `bin/pythonX.Y` into the Python.app
    bundle inside the framework (visible in `ps`, hidden from
    sys.executable) — grants must go to that bundle, not the launcher.
    """
    from pathlib import Path

    real = Path(real_executable)
    app_bundle = real.parent.parent / "Resources" / "Python.app"
    return str(app_bundle) if app_bundle.exists() else str(real)


def grant_target() -> str:  # pragma: no cover - depends on live interpreter
    import os
    import sys

    return _grant_target_for(os.path.realpath(sys.executable))


def default_probes() -> dict:  # pragma: no cover - OS/TCC probes
    from pathlib import Path

    def mic() -> bool:
        from AVFoundation import AVCaptureDevice, AVMediaTypeAudio

        return int(AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio)) == 3

    def accessibility() -> bool:
        from ApplicationServices import AXIsProcessTrusted

        return bool(AXIsProcessTrusted())

    def input_monitoring() -> bool:
        import Quartz

        return bool(Quartz.CGPreflightListenEventAccess())

    def models_cached() -> bool:
        from scribe.config import DEFAULT_PATH, load_config

        cfg, _ = load_config(DEFAULT_PATH)
        hub = Path("~/.cache/huggingface/hub").expanduser()
        repos = (cfg.stt.parakeet_model, cfg.cleanup.model)
        return all((hub / f"models--{r.replace('/', '--')}").exists() for r in repos)

    target = grant_target()
    return {
        "microphone": (mic, "System Settings → Privacy & Security → Microphone"),
        "accessibility": (
            accessibility,
            f"System Settings → Privacy & Security → Accessibility → “+” → ⌘⇧G → {target}",
        ),
        "input monitoring": (
            input_monitoring,
            f"System Settings → Privacy & Security → Input Monitoring → “+” → ⌘⇧G → {target}",
        ),
        "models cached": (models_cached, "run: make test-models (downloads on first use)"),
    }


def main() -> int:  # pragma: no cover - CLI entry
    checks = run_checks(default_probes())
    print(format_report(checks))
    if not all(c.ok for c in checks):
        print(f"\ngrant permissions to: {grant_target()}")
    return 0 if all(c.ok for c in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())

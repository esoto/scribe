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

    return {
        "microphone": (mic, "System Settings → Privacy & Security → Microphone"),
        "accessibility": (accessibility, "System Settings → Privacy & Security → Accessibility"),
        "input monitoring": (
            input_monitoring,
            "System Settings → Privacy & Security → Input Monitoring",
        ),
        "models cached": (models_cached, "run: make test-models (downloads on first use)"),
    }


def main() -> int:  # pragma: no cover - CLI entry
    checks = run_checks(default_probes())
    print(format_report(checks))
    return 0 if all(c.ok for c in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())

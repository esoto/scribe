"""Typed configuration with tolerant TOML loading.

Invalid fields fall back to defaults and produce warning strings instead of
failing the app at login (spec §5: degrade, never die).
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PATH = Path("~/.config/scribe/config.toml").expanduser()

VALID_KEYS = ("right_command", "right_option", "f13")
VALID_ENGINES = ("parakeet", "whisper")


@dataclass(frozen=True)
class Hotkey:
    key: str = "right_command"
    hold_threshold_s: float = 0.3


@dataclass(frozen=True)
class Stt:
    engine: str = "parakeet"
    parakeet_model: str = "mlx-community/parakeet-tdt-0.6b-v3"
    whisper_model: str = "mlx-community/whisper-large-v3-turbo"


@dataclass(frozen=True)
class Cleanup:
    enabled: bool = True
    model: str = "mlx-community/gemma-3-4b-it-qat-4bit"
    min_words: int = 4
    timeout_s: float = 6.0
    length_band: tuple[float, float] = (0.5, 1.3)


@dataclass(frozen=True)
class Paste:
    clipboard_restore_delay_s: float = 2.0


@dataclass(frozen=True)
class Audio:
    sample_rate: int = 16000
    energy_gate_rms: float = 0.0005


@dataclass(frozen=True)
class Ui:
    sounds: bool = True
    history_size: int = 10


@dataclass(frozen=True)
class Memory:
    # Minutes without dictation before models unload (~5 GB reclaimed);
    # 0 disables. The next dictation transparently reloads (a few seconds).
    idle_unload_minutes: float = 15.0


@dataclass(frozen=True)
class Config:
    hotkey: Hotkey = field(default_factory=Hotkey)
    stt: Stt = field(default_factory=Stt)
    cleanup: Cleanup = field(default_factory=Cleanup)
    paste: Paste = field(default_factory=Paste)
    audio: Audio = field(default_factory=Audio)
    ui: Ui = field(default_factory=Ui)
    memory: Memory = field(default_factory=Memory)


def _positive(v: float) -> bool:
    return v > 0


_SCHEMA: dict[str, dict[str, tuple[type | tuple[type, ...], object]]] = {
    "hotkey": {
        "key": (str, lambda v: v in VALID_KEYS),
        "hold_threshold_s": ((int, float), lambda v: 0 < v <= 5),
    },
    "stt": {
        "engine": (str, lambda v: v in VALID_ENGINES),
        "parakeet_model": (str, lambda v: bool(v)),
        "whisper_model": (str, lambda v: bool(v)),
    },
    "cleanup": {
        "enabled": (bool, lambda v: True),
        "model": (str, lambda v: bool(v)),
        "min_words": (int, lambda v: v >= 0),
        "timeout_s": ((int, float), _positive),
        "length_band": (list, lambda v: len(v) == 2 and 0 < v[0] < 1 <= v[1] <= 3),
    },
    "paste": {
        "clipboard_restore_delay_s": ((int, float), lambda v: v >= 0),
    },
    "audio": {
        "sample_rate": (int, _positive),
        "energy_gate_rms": ((int, float), lambda v: v >= 0),
    },
    "ui": {
        "sounds": (bool, lambda v: True),
        "history_size": (int, _positive),
    },
    "memory": {
        "idle_unload_minutes": ((int, float), lambda v: v >= 0),
    },
}

_SECTIONS = {
    "hotkey": Hotkey,
    "stt": Stt,
    "cleanup": Cleanup,
    "paste": Paste,
    "audio": Audio,
    "ui": Ui,
    "memory": Memory,
}


def load_config(path: Path) -> tuple[Config, list[str]]:
    warnings: list[str] = []
    if not path.exists():
        return Config(), warnings
    try:
        data = tomllib.loads(path.read_text())
    except (tomllib.TOMLDecodeError, OSError) as e:
        return Config(), [f"config unreadable ({e}); using all defaults"]

    sections = {}
    for section, cls in _SECTIONS.items():
        raw = data.get(section, {})
        if not isinstance(raw, dict):
            warnings.append(f"{section}: expected a table, using defaults")
            raw = {}
        values = {}
        for name, (types, valid) in _SCHEMA[section].items():
            if name not in raw:
                continue
            v = raw[name]
            # bool is an int subclass; reject True where an int is expected
            type_ok = isinstance(v, types) and not (
                isinstance(v, bool) and types in (int, (int, float))
            )
            if not type_ok or not valid(v):
                warnings.append(f"{section}.{name}: invalid value {v!r}, using default")
                continue
            values[name] = tuple(v) if name == "length_band" else v
        sections[section] = cls(**values)
    return Config(**sections), warnings

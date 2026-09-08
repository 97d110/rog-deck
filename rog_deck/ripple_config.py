"""Persisted ripple settings, shared by the dashboard and the Omarchy widget.

The running effect watches this file's mtime and picks changes up live, so a
colour change from either UI takes effect without restarting the service.
"""

from __future__ import annotations

import json
import os
from typing import Any

CONFIG_DIR = os.path.expanduser("~/.config/rog-deck")
CONFIG_PATH = os.path.join(CONFIG_DIR, "ripple.json")

DEFAULTS: dict[str, Any] = {
    "colour": "#3caaff",
    "brightness": 1.0,   # ceiling for the whole effect, 0..1
    "speed": 9.0,        # wavefront speed, key-units/sec
    "decay": 0.45,       # seconds for a lit key to fade
    "steps": 0,          # 0 = smooth trail, N = N visible bands
    "base": 0.0,         # idle glow; a floor here leaves keys permanently dim
    # The underside bar's right-hand zones share bytes with VolDown and VolUp,
    # so a full-width bar necessarily lights those two keys along with it.
    # True  = bar spans the whole width, volume keys glow with it.
    # False = volume keys stay dark, bar covers only its left half.
    "lightbar_full_width": True,
}

LIMITS = {
    "brightness": (0.0, 1.0),
    "speed": (1.0, 30.0),
    "decay": (0.05, 3.0),
    "steps": (0, 12),
    "base": (0.0, 0.5),
}


def _clamp(key: str, value: float) -> float:
    lo, hi = LIMITS[key]
    return max(lo, min(hi, value))


def load() -> dict[str, Any]:
    values = dict(DEFAULTS)
    try:
        with open(CONFIG_PATH) as fh:
            stored = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return values

    if isinstance(stored, dict):
        for key in DEFAULTS:
            if key in stored:
                values[key] = stored[key]
    return normalise(values)


def normalise(values: dict[str, Any]) -> dict[str, Any]:
    out = dict(DEFAULTS)
    for key, value in values.items():
        if key not in DEFAULTS:
            continue
        if key == "colour":
            text = str(value).strip()
            if not text.startswith("#"):
                text = "#" + text
            # Keep a bad colour from blacking out the keyboard silently.
            if len(text) != 7 or any(c not in "0123456789abcdefABCDEF" for c in text[1:]):
                text = DEFAULTS["colour"]
            out[key] = text.lower()
        elif key == "lightbar_full_width":
            out[key] = bool(value)
        elif key == "steps":
            out[key] = int(_clamp(key, int(value)))
        else:
            out[key] = round(float(_clamp(key, float(value))), 3)
    return out


def save(values: dict[str, Any]) -> dict[str, Any]:
    merged = normalise({**load(), **values})
    os.makedirs(CONFIG_DIR, exist_ok=True)
    # Write-then-rename so a reader never sees a half-written file.
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(merged, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, CONFIG_PATH)
    return merged


def mtime() -> float:
    try:
        return os.path.getmtime(CONFIG_PATH)
    except OSError:
        return 0.0


def rgb(colour: str) -> tuple[int, int, int]:
    raw = colour.lstrip("#")
    return tuple(int(raw[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]

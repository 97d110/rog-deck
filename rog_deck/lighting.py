"""One owner for keyboard lighting, so the controls cannot contradict.

The keyboard has exactly one lighting behaviour at a time, but three things
were competing for it: a built-in Aura effect, the reactive ripple (which puts
the keyboard into direct mode and streams frames), and the brightness level.
Setting an Aura effect while the ripple ran did nothing visible, brightness
writes were rejected while the ripple held asusd's lock, and none of the
effect parameters were remembered - so speed, direction and the second colour
were silently hardcoded at the call site.

This models it as a single mode with persisted parameters, and applies a mode
as one atomic sequence, so whatever the UI last said is what the hardware is
doing.
"""

from __future__ import annotations

import json
import os
from typing import Any

from . import asus, ripple_config

CONFIG_DIR = os.path.expanduser("~/.config/rog-deck")
CONFIG_PATH = os.path.join(CONFIG_DIR, "lighting.json")

MODES = ("off", "effect", "ripple")

DEFAULTS: dict[str, Any] = {
    "mode": "effect",
    "effect": "static",
    "colour": "#3caaff",
    "colour2": "#c678dd",
    "speed": "med",
    "direction": "left",
    "brightness": "med",
}


def _colour(value: Any, fallback: str) -> str:
    text = str(value).strip()
    if not text.startswith("#"):
        text = "#" + text
    if len(text) != 7 or any(c not in "0123456789abcdefABCDEF" for c in text[1:]):
        return fallback
    return text.lower()


def normalise(values: dict[str, Any]) -> dict[str, Any]:
    out = dict(DEFAULTS)
    for key, value in (values or {}).items():
        if key not in DEFAULTS:
            continue
        if key == "mode":
            out[key] = value if value in MODES else DEFAULTS[key]
        elif key == "effect":
            out[key] = value if value in asus.AURA_EFFECT_ARGS else DEFAULTS[key]
        elif key == "speed":
            out[key] = value if value in asus.AURA_SPEEDS else DEFAULTS[key]
        elif key == "direction":
            out[key] = value if value in asus.AURA_DIRECTIONS else DEFAULTS[key]
        elif key == "brightness":
            out[key] = value if value in asus.AURA_BRIGHTNESS else DEFAULTS[key]
        else:
            out[key] = _colour(value, DEFAULTS[key])
    return out


def load() -> dict[str, Any]:
    try:
        with open(CONFIG_PATH) as fh:
            return normalise(json.load(fh))
    except (OSError, json.JSONDecodeError):
        return dict(DEFAULTS)


def save(values: dict[str, Any]) -> dict[str, Any]:
    merged = normalise({**load(), **(values or {})})
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(merged, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, CONFIG_PATH)
    return merged


RIPPLE_UNIT = "rog-deck-ripple.service"


def ripple_running() -> bool:
    try:
        return asus.run("systemctl", "--user", "is-active", RIPPLE_UNIT) == "active"
    except asus.CommandError:
        return False


def _set_ripple(running: bool) -> None:
    action = "start" if running else "stop"
    try:
        asus.run("systemctl", "--user", action, RIPPLE_UNIT)
    except asus.CommandError as exc:
        raise asus.CommandError(f"could not {action} the ripple: {exc}") from exc


def apply(values: dict[str, Any] | None = None) -> dict[str, Any]:
    """Persist settings then drive the hardware into that exact state."""
    config = save(values or {})
    mode = config["mode"]

    # Always settle the ripple first: while it streams it owns the keyboard in
    # direct mode and holds asusd's aura lock, so brightness and effect writes
    # are silently dropped. Stopping it first is what makes the rest stick.
    if mode != "ripple" and ripple_running():
        _set_ripple(False)

    if mode == "off":
        asus.set_aura_brightness("off")
        return status()

    asus.set_aura_brightness(config["brightness"] if config["brightness"] != "off"
                             else "med")

    if mode == "effect":
        accepted = asus.AURA_EFFECT_ARGS.get(config["effect"], ())
        asus.set_aura_effect(
            config["effect"],
            colour=config["colour"] if "colour" in accepted else None,
            colour2=config["colour2"] if "colour2" in accepted else None,
            speed=config["speed"] if "speed" in accepted else None,
            direction=config["direction"] if "direction" in accepted else None,
        )
    elif mode == "ripple":
        if not ripple_running():
            _set_ripple(True)

    return status()


def status() -> dict[str, Any]:
    config = load()
    aura = asus.aura()
    ripple = ripple_config.load()
    return {
        "settings": config,
        "modes": list(MODES),
        "effects": asus.AURA_EFFECTS,
        "effect_args": asus.AURA_EFFECT_ARGS,
        "speeds": asus.AURA_SPEEDS,
        "directions": asus.AURA_DIRECTIONS,
        "brightness_choices": asus.AURA_BRIGHTNESS,
        # What the hardware actually reports, so the UI can show a mismatch
        # rather than pretending.
        "hardware_brightness": aura.get("brightness"),
        "ripple_running": ripple_running(),
        "ripple": ripple,
        "ripple_limits": ripple_config.LIMITS,
    }

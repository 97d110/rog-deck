"""Adapters over the ASUS platform.

Reads come from sysfs, which is world-readable and cheap enough to poll.
Writes go through `asusctl`, which talks to the root-owned asusd over D-Bus -
every knob under /sys is root:root 0644, so writing directly would need
privileges the dashboard deliberately does not have.
"""

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
from typing import Any

FW_ATTRS = "/sys/class/firmware-attributes/asus-armoury/attributes"
PLATFORM_PROFILE = "/sys/firmware/acpi/platform_profile"
PLATFORM_PROFILE_CHOICES = "/sys/firmware/acpi/platform_profile_choices"
NUMPAD_CONFIG = "/usr/share/asus-numberpad-driver/numberpad_dev"

# asusd greets some calls with this on stdout; it is not an error.
_ASUSD_NOISE = re.compile(r"^\s*Multiple asusd interfaces devices found\s*$", re.M)


class CommandError(RuntimeError):
    """A helper binary failed. Carries the output so the UI can show it."""


def _read(path: str) -> str | None:
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None


def _read_int(path: str) -> int | None:
    raw = _read(path)
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def have(binary: str) -> bool:
    return shutil.which(binary) is not None


def run(*argv: str, timeout: float = 15.0) -> str:
    """Run a helper binary, returning stdout with asusd's banner stripped."""
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout, check=False
        )
    except FileNotFoundError as exc:
        raise CommandError(f"{argv[0]} is not installed") from exc
    except subprocess.TimeoutExpired as exc:
        raise CommandError(f"{' '.join(argv)} timed out") from exc

    out = _ASUSD_NOISE.sub("", proc.stdout or "").strip()
    if proc.returncode != 0:
        detail = (proc.stderr or out or "").strip()
        raise CommandError(detail or f"{argv[0]} exited {proc.returncode}")
    return out


# --------------------------------------------------------------------------
# Firmware attributes (the "Armoury" knobs: power limits, GPU mux, ...)
# --------------------------------------------------------------------------

# Ranges are not static: the firmware narrows the PPT limits according to the
# active platform profile, so these are re-read on every request rather than
# cached at startup.
def firmware_attributes() -> list[dict[str, Any]]:
    attrs = []
    for path in sorted(glob.glob(f"{FW_ATTRS}/*")):
        if not os.path.isdir(path):
            continue
        name = os.path.basename(path)
        kind = _read(f"{path}/type") or "integer"
        attr: dict[str, Any] = {
            "name": name,
            "type": kind,
            "label": _read(f"{path}/display_name") or name,
            "current": _read_int(f"{path}/current_value"),
            "default": _read_int(f"{path}/default_value"),
        }
        if kind == "enumeration":
            raw = _read(f"{path}/possible_values") or ""
            attr["choices"] = [int(v) for v in raw.split(";") if v.strip().isdigit()]
        else:
            attr["min"] = _read_int(f"{path}/min_value")
            attr["max"] = _read_int(f"{path}/max_value")
            attr["step"] = _read_int(f"{path}/scalar_increment") or 1
        attrs.append(attr)
    return attrs


def set_firmware_attribute(name: str, value: int) -> None:
    # Guard against path traversal and against writing knobs the firmware on
    # this machine does not actually expose.
    if not os.path.isdir(os.path.join(FW_ATTRS, os.path.basename(name))):
        raise CommandError(f"unknown firmware attribute: {name}")
    run("asusctl", "armoury", "set", os.path.basename(name), str(int(value)))


def pending_reboot() -> bool:
    return _read_int(f"{FW_ATTRS}/pending_reboot") == 1


# --------------------------------------------------------------------------
# Platform profile
# --------------------------------------------------------------------------

def platform_profile() -> dict[str, Any]:
    """Active profile plus asusd's per-power-source defaults.

    asusd keeps a profile for AC and another for battery and swaps the active
    one when you plug or unplug, which otherwise looks like the dashboard
    changing settings on its own.
    """
    choices = (_read(PLATFORM_PROFILE_CHOICES) or "").split()
    info: dict[str, Any] = {"current": _read(PLATFORM_PROFILE), "choices": choices}

    try:
        out = run("asusctl", "profile", "get")
        for key, pattern in (("ac", r"AC profile\s+(\w+)"),
                             ("battery", r"Battery profile\s+(\w+)")):
            match = re.search(pattern, out)
            if match:
                info[f"{key}_profile"] = match.group(1).lower()
    except CommandError:
        pass

    return info


def set_platform_profile(profile: str, on_ac: bool | None = None) -> None:
    choices = (_read(PLATFORM_PROFILE_CHOICES) or "").split()
    if profile not in choices:
        raise CommandError(f"profile must be one of {choices}")

    # The profile is a positional argument; -a/-b instead set the default used
    # for that power source.
    argv = ["asusctl", "profile", "set"]
    if on_ac is True:
        argv.append("-a")
    elif on_ac is False:
        argv.append("-b")
    argv.append(profile.capitalize())
    run(*argv)


# --------------------------------------------------------------------------
# Battery
# --------------------------------------------------------------------------

def battery() -> dict[str, Any]:
    base = next(iter(glob.glob("/sys/class/power_supply/BAT*")), None)
    if base is None:
        return {"present": False}
    return {
        "present": True,
        "capacity": _read_int(f"{base}/capacity"),
        "status": _read(f"{base}/status"),
        "charge_limit": _read_int(f"{base}/charge_control_end_threshold"),
    }


def set_charge_limit(percent: int) -> None:
    percent = int(percent)
    if not 20 <= percent <= 100:
        raise CommandError("charge limit must be between 20 and 100")
    run("asusctl", "battery", "limit", str(percent))


# --------------------------------------------------------------------------
# Fan curves
# --------------------------------------------------------------------------

_CURVE_BLOCK = re.compile(
    r"fan:\s*(?P<fan>\w+),\s*pwm:\s*\((?P<pwm>[^)]*)\),\s*temp:\s*\((?P<temp>[^)]*)\)",
    re.S,
)


def fan_curves(profile: str) -> list[dict[str, Any]]:
    """Parse `asusctl fan-curve --mod-profile X` into per-fan point lists."""
    out = run("asusctl", "fan-curve", "--mod-profile", profile)
    curves = []
    for match in _CURVE_BLOCK.finditer(out):
        pwm = [int(v) for v in match.group("pwm").replace(" ", "").split(",") if v]
        temp = [int(v) for v in match.group("temp").replace(" ", "").split(",") if v]
        curves.append(
            {
                "fan": match.group("fan").lower(),
                # PWM is 0-255 on the wire; percent is friendlier in a UI.
                "points": [
                    {"temp": t, "pwm": p, "percent": round(p * 100 / 255)}
                    for t, p in zip(temp, pwm)
                ],
            }
        )
    return curves


def set_fan_curve(profile: str, fan: str, points: list[dict[str, int]]) -> None:
    if fan not in {"cpu", "gpu", "mid"}:
        raise CommandError("fan must be cpu, gpu or mid")
    if not points:
        raise CommandError("a fan curve needs at least one point")
    data = ",".join(f"{int(p['temp'])}c:{int(p['percent'])}%" for p in points)
    run(
        "asusctl", "fan-curve",
        "--mod-profile", profile,
        "--fan", fan,
        "--data", data,
    )
    run(
        "asusctl", "fan-curve",
        "--mod-profile", profile,
        "--enable-fan-curve", "true",
        "--fan", fan,
    )


def reset_fan_curves(profile: str) -> None:
    run("asusctl", "fan-curve", "--mod-profile", profile, "--default")


# --------------------------------------------------------------------------
# Aura (keyboard RGB) and the Slash lid ledbar
# --------------------------------------------------------------------------

AURA_BRIGHTNESS = ["off", "low", "med", "high"]
AURA_SPEEDS = ["low", "med", "high"]
AURA_DIRECTIONS = ["up", "down", "left", "right"]

# Every effect takes a different set of arguments, and asusctl errors out if it
# is handed one the effect does not accept - passing --colour to rainbow-cycle
# is a hard failure, not a no-op. This table mirrors
# `asusctl aura effect <name> --help` exactly, and the UI uses it to show only
# the controls an effect actually supports. Long flags throughout: breathe and
# stars accept --colour but NOT the -c short form the others allow.
AURA_EFFECT_ARGS: dict[str, tuple[str, ...]] = {
    "static":        ("colour",),
    "breathe":       ("colour", "colour2", "speed"),
    "rainbow-cycle": ("speed",),
    "rainbow-wave":  ("speed", "direction"),
    "stars":         ("colour", "colour2", "speed"),
    "rain":          ("speed",),
    "highlight":     ("colour", "speed"),
    "laser":         ("colour", "speed"),
    "ripple":        ("colour", "speed"),
    "pulse":         ("colour",),
    "comet":         ("colour",),
    "flash":         ("colour",),
}
AURA_EFFECTS = list(AURA_EFFECT_ARGS)


KBD_BACKLIGHT = "/sys/class/leds/asus::kbd_backlight"


def keyboard_brightness() -> str | None:
    """Backlight level as off/low/med/high, straight from the LED class.

    Read from sysfs rather than `asusctl leds get`, which reports "Off" while
    another client streams direct frames (asusd will not hand over the aura
    lock) and does not reflect changes made with the keyboard's own Fn keys
    promptly. sysfs is authoritative and needs no lock.
    """
    level = _read_int(f"{KBD_BACKLIGHT}/brightness")
    top = _read_int(f"{KBD_BACKLIGHT}/max_brightness")
    if level is None or not top:
        return None
    index = round(level / top * (len(AURA_BRIGHTNESS) - 1))
    return AURA_BRIGHTNESS[max(0, min(len(AURA_BRIGHTNESS) - 1, index))]


def aura() -> dict[str, Any]:
    brightness = keyboard_brightness()
    if brightness is None:
        try:
            out = run("asusctl", "leds", "get")
            match = re.search(r":\s*(\w+)", out)
            if match:
                brightness = match.group(1).lower()
        except CommandError:
            pass
    return {
        "brightness": brightness,
        "brightness_choices": AURA_BRIGHTNESS,
        "effects": AURA_EFFECTS,
        "effect_args": AURA_EFFECT_ARGS,
        "speeds": AURA_SPEEDS,
        "directions": AURA_DIRECTIONS,
    }


def set_aura_brightness(level: str) -> None:
    if level not in AURA_BRIGHTNESS:
        raise CommandError(f"brightness must be one of {AURA_BRIGHTNESS}")
    run("asusctl", "leds", "set", level)


def set_aura_effect(effect: str, colour: str | None = None,
                    colour2: str | None = None, speed: str | None = None,
                    direction: str | None = None) -> None:
    """Apply an aura effect, sending only the flags it actually accepts."""
    accepted = AURA_EFFECT_ARGS.get(effect)
    if accepted is None:
        raise CommandError(f"unknown effect: {effect}")

    supplied = {
        "colour": colour, "colour2": colour2,
        "speed": speed, "direction": direction,
    }

    if speed and "speed" in accepted and speed not in AURA_SPEEDS:
        raise CommandError(f"speed must be one of {AURA_SPEEDS}")
    if direction and "direction" in accepted and direction not in AURA_DIRECTIONS:
        raise CommandError(f"direction must be one of {AURA_DIRECTIONS}")

    argv = ["asusctl", "aura", "effect", effect]
    for name in accepted:
        value = supplied.get(name)
        if not value:
            continue
        if name in {"colour", "colour2"}:
            value = str(value).lstrip("#")
        argv += [f"--{name}", str(value)]
    run(*argv)


def slash() -> dict[str, Any]:
    """The lid light bar. `--list` is the only read asusctl offers."""
    modes: list[str] = []
    try:
        out = run("asusctl", "slash", "--list")
        modes = re.findall(r'"([^"]+)"', out)
    except CommandError:
        pass
    return {"supported": bool(modes), "modes": modes}


def set_slash_enabled(enabled: bool) -> None:
    run("asusctl", "slash", "--enable" if enabled else "--disable")


def set_slash_mode(mode: str) -> None:
    modes = slash()["modes"]
    if mode not in modes:
        raise CommandError(f"unknown slash mode: {mode}")
    run("asusctl", "slash", "--mode", mode)


def set_slash_brightness(value: int) -> None:
    value = int(value)
    if not 0 <= value <= 255:
        raise CommandError("slash brightness must be 0-255")
    run("asusctl", "slash", "-l", str(value))


SLASH_TOGGLES = {
    "show_on_boot": "-B",
    "show_on_shutdown": "-S",
    "show_on_sleep": "-s",
    "show_on_battery": "-b",
    "show_battery_warning": "-w",
}


def set_slash_toggle(name: str, enabled: bool) -> None:
    flag = SLASH_TOGGLES.get(name)
    if flag is None:
        raise CommandError(f"unknown slash toggle: {name}")
    run("asusctl", "slash", flag, "true" if enabled else "false")


# --------------------------------------------------------------------------
# GPU mode (supergfxctl)
# --------------------------------------------------------------------------

def graphics() -> dict[str, Any]:
    if not have("supergfxctl"):
        return {"supported": False}
    try:
        mode = run("supergfxctl", "-g")
        pending = None
        try:
            pending = run("supergfxctl", "-P")
        except CommandError:
            pass
        return {
            "supported": True,
            "mode": mode.strip(),
            "pending": pending.strip() if pending else None,
            "choices": ["Hybrid", "Integrated", "AsusMuxDgpu", "Vfio", "NvidiaNoModeset"],
        }
    except CommandError as exc:
        return {"supported": False, "error": str(exc)}


def set_graphics_mode(mode: str) -> None:
    run("supergfxctl", "-m", mode)


# --------------------------------------------------------------------------
# Trackpad NumberPad
# --------------------------------------------------------------------------

def numpad() -> dict[str, Any]:
    """The NumberPad driver keeps a 2-way-synced ini; `enabled` is live state."""
    if not os.path.exists(NUMPAD_CONFIG):
        return {"supported": False}
    values: dict[str, str] = {}
    with open(NUMPAD_CONFIG) as fh:
        for line in fh:
            if "=" in line and not line.lstrip().startswith(("#", "[")):
                key, _, val = line.partition("=")
                values[key.strip()] = val.strip()
    return {
        "supported": True,
        "enabled": values.get("enabled") in {"1", "True", "true"},
        "brightness": values.get("default_backlight_level"),
        "inactivity_timeout": values.get("disable_due_inactivity_time"),
        "activation_time": values.get("activation_time"),
    }


def set_numpad_value(key: str, value: str) -> None:
    """Rewrite one key in place. The driver watches the file and reacts."""
    allowed = {
        "enabled", "default_backlight_level",
        "disable_due_inactivity_time", "activation_time",
    }
    if key not in allowed:
        raise CommandError(f"numpad key not settable: {key}")
    if not os.path.exists(NUMPAD_CONFIG):
        raise CommandError("the NumberPad driver is not installed")

    with open(NUMPAD_CONFIG) as fh:
        lines = fh.readlines()

    prefix = f"{key} ="
    for index, line in enumerate(lines):
        if line.split("=")[0].strip() == key:
            lines[index] = f"{prefix} {value}\n"
            break
    else:
        lines.append(f"{prefix} {value}\n")

    try:
        with open(NUMPAD_CONFIG, "w") as fh:
            fh.writelines(lines)
    except OSError as exc:
        raise CommandError(
            f"cannot write {NUMPAD_CONFIG}: {exc}. The NumberPad installer "
            "chowns this file to the installing user."
        ) from exc


def set_numpad_enabled(enabled: bool) -> None:
    set_numpad_value("enabled", "1" if enabled else "0")

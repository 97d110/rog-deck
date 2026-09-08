"""Work out where each keyboard LED physically sits.

The LED->packet mapping is baked in (see led_table), but the *physical*
arrangement differs per model, so it is read at runtime from the layout files
rog-control-center ships. That keeps this working on any per-key ROG board
rather than hard-coding one keyboard.
"""

from __future__ import annotations

import glob
import os
import re
from dataclasses import dataclass

from .led_table import LED_OFFSETS

AURA_SUPPORT = "/usr/share/asusd/aura_support.ron"
LAYOUT_DIRS = ["/usr/share/rog-gui/layouts", "/usr/share/asusd/layouts"]

# Wide keys carry several LEDs; lighting all of them keeps a ripple smooth
# instead of making the spacebar blink as one block.
MULTI = {"Backspace": 3, "LShift": 3, "Return": 3, "Rshift": 3, "Spacebar": 5}


@dataclass(frozen=True)
class Led:
    name: str      # LED table key, e.g. "Spacebar5_3"
    key: str       # logical key, e.g. "Spacebar"
    packet: int
    offset: int
    x: float
    y: float


def board_name() -> str:
    try:
        with open("/sys/class/dmi/id/board_name") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def layout_for_board(board: str) -> tuple[str | None, str | None]:
    """Return (layout_name, advanced_type) for a board from aura_support.ron."""
    try:
        text = open(AURA_SUPPORT).read()
    except OSError:
        return None, None

    # Entries are RON tuples; match the longest device_name that prefixes the
    # board, since the table mixes exact names ("G614FR") with families
    # ("G614J").
    best: tuple[int, str, str] | None = None
    for match in re.finditer(
        r'device_name:\s*"([^"]*)".*?layout_name:\s*"([^"]*)".*?advanced_type:\s*(\w+)',
        text, re.S,
    ):
        name, layout, advanced = match.groups()
        if name and board.startswith(name):
            if best is None or len(name) > best[0]:
                best = (len(name), layout, advanced)
    if best is None:
        return None, None
    return best[1], best[2]


def _layout_file(layout_name: str) -> str | None:
    for directory in LAYOUT_DIRS:
        hits = sorted(glob.glob(os.path.join(directory, f"{layout_name}_*.ron")))
        if hits:
            # Prefer a US layout when several locales are present.
            us = [h for h in hits if "_US" in h]
            return (us or hits)[0]
    return None


def _parse_shapes(text: str) -> dict[str, dict]:
    shapes: dict[str, dict] = {}
    block = text.split("key_shapes:", 1)[1].split("key_rows:", 1)[0]
    for match in re.finditer(r'"([^"]+)":\s*(Led|Blank)\((.*?)\)', block, re.S):
        name, kind, body = match.groups()
        nums = dict(re.findall(r"(\w+):\s*([0-9.]+)", body))
        shapes[name] = {
            "kind": kind,
            "width": float(nums.get("width", 1.0)),
            "height": float(nums.get("height", 1.0)),
            "pad_left": float(nums.get("pad_left", 0.0)),
            "pad_right": float(nums.get("pad_right", 0.0)),
        }
    return shapes


def load_leds() -> tuple[list[Led], float, float]:
    """Every addressable LED with a physical position, plus the board extent."""
    board = board_name()
    layout_name, advanced = layout_for_board(board)
    if not layout_name or advanced != "PerKey":
        return [], 0.0, 0.0

    path = _layout_file(layout_name)
    if path is None:
        return [], 0.0, 0.0

    text = open(path).read()
    shapes = _parse_shapes(text)
    rows_block = text.split("key_rows:", 1)[1]
    row_chunks = re.findall(r"\(\s*pad_left:.*?row:\s*\[(.*?)\]\s*,?\s*\)", rows_block, re.S)

    leds: list[Led] = []
    y = 0.0
    for chunk in row_chunks:
        entries = re.findall(r"\(\s*([A-Za-z0-9_]+)\s*,\s*\"([^\"]+)\"\s*\)", chunk)
        x = 0.0
        row_height = 1.0
        for key, shape_name in entries:
            shape = shapes.get(shape_name)
            if shape is None:
                continue
            advance = shape["width"] + shape["pad_left"] + shape["pad_right"]
            if shape["kind"] == "Led" and key not in ("Spacing", "Blocking"):
                row_height = max(row_height, shape["height"])
                centre_y = y + shape["height"] / 2
                count = MULTI.get(key, 1)
                for i in range(count):
                    # Spread a wide key's LEDs evenly across its own width.
                    frac = (i + 0.5) / count
                    led_x = x + advance * frac
                    name = key if count == 1 else f"{key}{count}_{i + 1}"
                    where = LED_OFFSETS.get(name)
                    if where is None and count > 1:
                        where = LED_OFFSETS.get(key)
                        name = key
                    if where is None:
                        continue
                    leds.append(Led(name=name, key=key, packet=where[0],
                                    offset=where[1], x=round(led_x, 3),
                                    y=round(centre_y, 3)))
            x += advance
        y += row_height

    width = max((l.x for l in leds), default=0.0)
    height = max((l.y for l in leds), default=0.0)
    return leds, width, height


# --- evdev keycode -> logical key ------------------------------------------
# Only what a ripple needs: the code identifies a position, nothing is stored.
KEYCODE_TO_KEY = {
    1: "Esc", 2: "N1", 3: "N2", 4: "N3", 5: "N4", 6: "N5", 7: "N6", 8: "N7",
    9: "N8", 10: "N9", 11: "N0", 12: "Hyphen", 13: "Equals", 14: "Backspace",
    15: "Tab", 16: "Q", 17: "W", 18: "E", 19: "R", 20: "T", 21: "Y", 22: "U",
    23: "I", 24: "O", 25: "P", 26: "LBracket", 27: "RBracket", 28: "Return",
    29: "LCtrl", 30: "A", 31: "S", 32: "D", 33: "F", 34: "G", 35: "H",
    36: "J", 37: "K", 38: "L", 39: "SemiColon", 40: "Quote", 41: "Tilde",
    42: "LShift", 43: "BackSlash", 44: "Z", 45: "X", 46: "C", 47: "V",
    48: "B", 49: "N", 50: "M", 51: "Comma", 52: "Period", 53: "FwdSlash",
    54: "Rshift", 56: "LAlt", 57: "Spacebar", 58: "Caps",
    59: "F1", 60: "F2", 61: "F3", 62: "F4", 63: "F5", 64: "F6", 65: "F7",
    66: "F8", 67: "F9", 68: "F10", 87: "F11", 88: "F12",
    97: "RCtrl", 100: "RAlt", 102: "Home", 103: "Up", 104: "PgUp",
    105: "Left", 106: "Right", 107: "End", 108: "Down", 109: "PgDn",
    111: "Del", 125: "Meta", 99: "PrtSc",
}


# --- identifying real typing keyboards -------------------------------------
# A power button, lid switch and "WMI hotkeys" device all advertise `kbd`, so
# matching on that alone makes this open input devices it has no business
# reading. Requiring the alphabet instead keeps the set to actual keyboards,
# which matters for a process that sees keystrokes.
_REQUIRED_KEYS = (16, 30, 44, 57)  # Q, A, Z, Space


def _key_bitmask(words: list[str]) -> int:
    """/proc prints the KEY bitmask as 64-bit words, least significant last."""
    value = 0
    for index, word in enumerate(reversed(words)):
        try:
            value |= int(word, 16) << (64 * index)
        except ValueError:
            return 0
    return value


def typing_keyboards() -> list[str]:
    """Event device paths for devices that report a full alphabet."""
    try:
        blocks = open("/proc/bus/input/devices").read().split("\n\n")
    except OSError:
        return []

    paths = []
    for block in blocks:
        handlers = ""
        keymask = 0
        for line in block.splitlines():
            if line.startswith("H: Handlers="):
                handlers = line.split("=", 1)[1]
            elif line.startswith("B: KEY="):
                keymask = _key_bitmask(line.split("=", 1)[1].split())
        if not handlers or not keymask:
            continue
        if not all(keymask >> code & 1 for code in _REQUIRED_KEYS):
            continue
        for token in handlers.split():
            if token.startswith("event"):
                paths.append(f"/dev/input/{token}")
                break
    return paths

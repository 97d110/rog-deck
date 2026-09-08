"""Read the active Omarchy theme so the dashboard matches the rest of the desk.

Omarchy themes all publish the same colors.toml schema (accent, background,
foreground, red/green/yellow/..., plus a light/dark mode flag), and the active
one is exposed at a stable path. Reading it means the dashboard re-themes
itself when the user runs `omarchy theme set`, instead of hard-coding a
palette that clashes.
"""

from __future__ import annotations

import os
import tomllib
from typing import Any

# Omarchy symlinks the active theme's directory here.
CURRENT_THEME = os.path.expanduser("~/.local/state/omarchy/current/theme")
THEME_NAME = os.path.expanduser("~/.local/state/omarchy/current/theme.name")
THEME_SEARCH = [
    os.path.expanduser("~/.config/omarchy/themes"),
    "/usr/share/omarchy/themes",
]

# Used when Omarchy is absent or its theme cannot be parsed. Mirrors the
# schema so the frontend needs no special case.
FALLBACK: dict[str, Any] = {
    "name": "default",
    "mode": "dark",
    "colors": {
        "accent": "#61afef",
        "selection": "#3e4451",
        "muted": "#5c6370",
        "background": "#1a1c20",
        "dark_background": "#15171a",
        "darker_background": "#0f1113",
        "lighter_background": "#2a2f37",
        "foreground": "#c8ccd4",
        "dark_foreground": "#5c6370",
        "bright_foreground": "#e7ecf2",
        "red": "#e06c75",
        "orange": "#d19a66",
        "yellow": "#e5c07b",
        "green": "#98c379",
        "cyan": "#56b6c2",
        "blue": "#61afef",
        "magenta": "#c678dd",
    },
}

# Only colour-ish scalars are forwarded; hyprland_active_border and friends
# are gradient strings meant for the compositor, not CSS.
_SKIP = {"hyprland_active_border"}


def _slug() -> str | None:
    try:
        with open(THEME_NAME) as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def _colors_path() -> str | None:
    direct = os.path.join(CURRENT_THEME, "colors.toml")
    if os.path.isfile(direct):
        return direct

    slug = _slug()
    if not slug:
        return None
    for base in THEME_SEARCH:
        candidate = os.path.join(base, slug, "colors.toml")
        if os.path.isfile(candidate):
            return candidate
    return None


def theme() -> dict[str, Any]:
    path = _colors_path()
    if path is None:
        return FALLBACK

    try:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return FALLBACK

    colors = {
        key: value
        for key, value in data.items()
        if key not in _SKIP
        and key != "mode"
        and isinstance(value, str)
        and value.startswith("#")
    }
    if not colors:
        return FALLBACK

    # Fill anything this theme omits, so the CSS never sees an undefined var.
    merged = dict(FALLBACK["colors"])
    merged.update(colors)

    slug = _slug() or "unknown"
    return {
        "name": slug.replace("-", " ").title(),
        "slug": slug,
        "mode": data.get("mode", "dark"),
        "colors": merged,
    }

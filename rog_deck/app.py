"""HTTP server for ROG Deck.

Deliberately stdlib-only: this is meant to be shareable on any Omarchy box
without pulling a web framework in, and `python` is always already present.

Binds to loopback by default. The API changes hardware state and has no
authentication, so exposing it on a LAN is opt-in via --host.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable

from . import __version__, asus, ripple_config, sensors, theme as theme_mod

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")

Handler = Callable[[dict[str, Any]], Any]
_GET: dict[str, Handler] = {}
_POST: dict[str, Handler] = {}


def get(path: str) -> Callable[[Handler], Handler]:
    def register(fn: Handler) -> Handler:
        _GET[path] = fn
        return fn
    return register


def post(path: str) -> Callable[[Handler], Handler]:
    def register(fn: Handler) -> Handler:
        _POST[path] = fn
        return fn
    return register


# --------------------------------------------------------------------------
# Sensor fan-out: one poller thread feeds every connected SSE client, so the
# cost of reading sysfs does not scale with the number of open tabs.
# --------------------------------------------------------------------------

class SensorHub:
    def __init__(self, interval: float = 1.5) -> None:
        self.interval = interval
        self._subscribers: set[queue.Queue] = set()
        self._lock = threading.Lock()
        self._latest: dict[str, Any] = {}
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        while True:
            try:
                snap = sensors.snapshot()
            except Exception as exc:  # a bad sensor must not kill the stream
                snap = {"error": str(exc), "timestamp": time.time()}
            self._latest = snap
            with self._lock:
                targets = list(self._subscribers)
            for sub in targets:
                try:
                    sub.put_nowait(snap)
                except queue.Full:
                    pass  # slow client; it will catch up on the next tick
            time.sleep(self.interval)

    @property
    def latest(self) -> dict[str, Any]:
        return self._latest or sensors.snapshot()

    def subscribe(self) -> queue.Queue:
        sub: queue.Queue = queue.Queue(maxsize=4)
        with self._lock:
            self._subscribers.add(sub)
        return sub

    def unsubscribe(self, sub: queue.Queue) -> None:
        with self._lock:
            self._subscribers.discard(sub)


hub = SensorHub()


# --------------------------------------------------------------------------
# Read endpoints
# --------------------------------------------------------------------------

@get("/api/state")
def state(_: dict[str, Any]) -> dict[str, Any]:
    profile = asus.platform_profile()
    return {
        "version": __version__,
        "model": _model(),
        "theme": theme_mod.theme(),
        "profile": profile,
        "attributes": asus.firmware_attributes(),
        "pending_reboot": asus.pending_reboot(),
        "battery": asus.battery(),
        "aura": asus.aura(),
        "slash": asus.slash(),
        "graphics": asus.graphics(),
        "numpad": asus.numpad(),
        "ripple": _ripple_state(),
        "fan_curves": _fan_curves_for(profile.get("current")),
    }


def _model() -> dict[str, str | None]:
    def read(path: str) -> str | None:
        try:
            with open(path) as fh:
                return fh.read().strip()
        except OSError:
            return None

    return {
        "product": read("/sys/class/dmi/id/product_name"),
        "family": read("/sys/class/dmi/id/product_family"),
        "board": read("/sys/class/dmi/id/board_name"),
    }


def _fan_curves_for(profile: str | None) -> dict[str, Any]:
    if not profile:
        return {"available": False, "reason": "no active platform profile"}
    try:
        return {"available": True, "profile": profile,
                "curves": asus.fan_curves(profile.capitalize())}
    except asus.CommandError as exc:
        return {"available": False, "reason": str(exc)}


RIPPLE_UNIT = "rog-deck-ripple.service"


def _ripple_state() -> dict[str, Any]:
    """Stored effect settings plus whether the effect is currently running."""
    def unit(*args: str) -> str:
        try:
            return asus.run("systemctl", "--user", *args, RIPPLE_UNIT)
        except asus.CommandError:
            # systemctl exits non-zero for inactive/disabled, which is an
            # answer rather than a failure.
            return ""

    installed = bool(unit("cat")) or bool(unit("is-enabled"))
    return {
        "supported": bool(_per_key_supported()),
        "installed": installed,
        "active": unit("is-active") == "active",
        "enabled": unit("is-enabled") == "enabled",
        "settings": ripple_config.load(),
        "limits": ripple_config.LIMITS,
    }


def _per_key_supported() -> bool:
    from .keyboard_layout import board_name, layout_for_board
    _, advanced = layout_for_board(board_name())
    return advanced == "PerKey"


@get("/api/ripple")
def ripple_now(_: dict[str, Any]) -> dict[str, Any]:
    return _ripple_state()


@post("/api/ripple")
def set_ripple(body: dict[str, Any]) -> dict[str, Any]:
    # Settings are written first so a start picks them up immediately.
    settings = {k: v for k, v in body.items() if k in ripple_config.DEFAULTS}
    if settings:
        ripple_config.save(settings)

    if "active" in body:
        action = "start" if body["active"] else "stop"
        try:
            asus.run("systemctl", "--user", action, RIPPLE_UNIT)
        except asus.CommandError as exc:
            raise asus.CommandError(
                f"could not {action} the ripple effect: {exc}") from exc

    if "enabled" in body:
        action = "enable" if body["enabled"] else "disable"
        try:
            asus.run("systemctl", "--user", action, RIPPLE_UNIT)
        except asus.CommandError as exc:
            raise asus.CommandError(f"could not {action} at login: {exc}") from exc

    return {"ripple": _ripple_state()}


@get("/api/theme")
def theme_now(_: dict[str, Any]) -> dict[str, Any]:
    return theme_mod.theme()


@get("/api/sensors")
def sensors_now(_: dict[str, Any]) -> dict[str, Any]:
    return hub.latest


@get("/api/fan-curves")
def fan_curves(params: dict[str, Any]) -> dict[str, Any]:
    profile = params.get("profile") or asus.platform_profile().get("current") or ""
    return _fan_curves_for(profile)


# --------------------------------------------------------------------------
# Write endpoints
# --------------------------------------------------------------------------

@post("/api/profile")
def set_profile(body: dict[str, Any]) -> dict[str, Any]:
    # "for" selects which slot to write: the live profile, or the default this
    # machine should use on AC / on battery.
    target = body.get("for")
    on_ac = {"ac": True, "battery": False}.get(target) if target else None
    asus.set_platform_profile(str(body["profile"]), on_ac)
    # The firmware re-scopes the PPT ranges per profile, so hand back a fresh
    # attribute set and the new curves instead of making the UI guess.
    profile = asus.platform_profile()
    return {
        "profile": profile,
        "attributes": asus.firmware_attributes(),
        "fan_curves": _fan_curves_for(profile.get("current")),
    }


@post("/api/attribute")
def set_attribute(body: dict[str, Any]) -> dict[str, Any]:
    asus.set_firmware_attribute(str(body["name"]), int(body["value"]))
    return {"attributes": asus.firmware_attributes(),
            "pending_reboot": asus.pending_reboot()}


@post("/api/battery-limit")
def set_battery_limit(body: dict[str, Any]) -> dict[str, Any]:
    asus.set_charge_limit(int(body["percent"]))
    return {"battery": asus.battery()}


@post("/api/fan-curve")
def set_fan_curve(body: dict[str, Any]) -> dict[str, Any]:
    profile = str(body.get("profile") or asus.platform_profile()["current"])
    asus.set_fan_curve(profile.capitalize(), str(body["fan"]), body["points"])
    return _fan_curves_for(profile)


@post("/api/fan-curve-reset")
def reset_fan_curve(body: dict[str, Any]) -> dict[str, Any]:
    profile = str(body.get("profile") or asus.platform_profile()["current"])
    asus.reset_fan_curves(profile.capitalize())
    return _fan_curves_for(profile)


@post("/api/aura-brightness")
def set_aura_brightness(body: dict[str, Any]) -> dict[str, Any]:
    asus.set_aura_brightness(str(body["level"]))
    return {"aura": asus.aura()}


@post("/api/aura-effect")
def set_aura_effect(body: dict[str, Any]) -> dict[str, Any]:
    asus.set_aura_effect(
        str(body["effect"]),
        body.get("colour"), body.get("colour2"), body.get("speed"),
    )
    return {"aura": asus.aura()}


@post("/api/slash")
def set_slash(body: dict[str, Any]) -> dict[str, Any]:
    if "enabled" in body:
        asus.set_slash_enabled(bool(body["enabled"]))
    if body.get("mode"):
        asus.set_slash_mode(str(body["mode"]))
    if "brightness" in body:
        asus.set_slash_brightness(int(body["brightness"]))
    for name in asus.SLASH_TOGGLES:
        if name in body:
            asus.set_slash_toggle(name, bool(body[name]))
    return {"slash": asus.slash()}


@post("/api/graphics")
def set_graphics(body: dict[str, Any]) -> dict[str, Any]:
    asus.set_graphics_mode(str(body["mode"]))
    return {"graphics": asus.graphics()}


@post("/api/numpad")
def set_numpad(body: dict[str, Any]) -> dict[str, Any]:
    if "enabled" in body:
        asus.set_numpad_enabled(bool(body["enabled"]))
    for key in ("default_backlight_level", "disable_due_inactivity_time",
                "activation_time"):
        if key in body:
            asus.set_numpad_value(key, str(body[key]))
    return {"numpad": asus.numpad()}


# --------------------------------------------------------------------------
# HTTP plumbing
# --------------------------------------------------------------------------

class Deck(BaseHTTPRequestHandler):
    server_version = f"rog-deck/{__version__}"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        if os.environ.get("ROG_DECK_DEBUG"):
            super().log_message(fmt, *args)

    # -- helpers ----------------------------------------------------------
    def _send_json(self, payload: Any, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _split(self) -> tuple[str, dict[str, str]]:
        path, _, raw = self.path.partition("?")
        params: dict[str, str] = {}
        for pair in raw.split("&"):
            if "=" in pair:
                key, _, value = pair.partition("=")
                params[key] = value
        return path.rstrip("/") or "/", params

    # -- routes -----------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        path, params = self._split()

        if path == "/api/stream":
            self._stream()
            return

        handler = _GET.get(path)
        if handler is not None:
            self._dispatch(handler, params)
            return

        self._static(path)

    def do_POST(self) -> None:  # noqa: N802
        path, _ = self._split()
        handler = _POST.get(path)
        if handler is None:
            self._send_json({"error": "not found"}, 404)
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json({"error": "invalid JSON body"}, 400)
            return

        self._dispatch(handler, body)

    def _dispatch(self, handler: Handler, payload: dict[str, Any]) -> None:
        try:
            self._send_json({"ok": True, "data": handler(payload)})
        except KeyError as exc:
            self._send_json({"ok": False, "error": f"missing field: {exc}"}, 400)
        except (asus.CommandError, ValueError) as exc:
            # Expected: the user asked for something the hardware refused.
            self._send_json({"ok": False, "error": str(exc)}, 400)
        except Exception as exc:  # pragma: no cover - unexpected
            self._send_json({"ok": False, "error": repr(exc)}, 500)

    def _stream(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        sub = hub.subscribe()
        try:
            # Prime the client so the UI paints immediately.
            self._emit(hub.latest)
            while True:
                try:
                    self._emit(sub.get(timeout=20))
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            hub.unsubscribe(sub)

    def _emit(self, snap: dict[str, Any]) -> None:
        self.wfile.write(f"data: {json.dumps(snap)}\n\n".encode())
        self.wfile.flush()

    def _static(self, path: str) -> None:
        rel = "index.html" if path == "/" else path.lstrip("/")
        target = os.path.normpath(os.path.join(STATIC_DIR, rel))
        if not target.startswith(STATIC_DIR) or not os.path.isfile(target):
            self._send_json({"error": "not found"}, 404)
            return

        kind = mimetypes.guess_type(target)[0] or "application/octet-stream"
        with open(target, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="rog-deck", description="ROG Deck server")
    parser.add_argument("--host", default="127.0.0.1",
                        help="bind address (default: loopback only)")
    parser.add_argument("--port", type=int, default=8737)
    parser.add_argument("--interval", type=float, default=1.5,
                        help="sensor poll interval in seconds")
    args = parser.parse_args(argv)

    hub.interval = args.interval
    hub.start()

    if args.host not in {"127.0.0.1", "localhost", "::1"}:
        print(f"!! Binding to {args.host}: the API can change hardware settings "
              "and has NO authentication. Only do this on a network you trust.")

    server = ThreadingHTTPServer((args.host, args.port), Deck)
    server.daemon_threads = True
    print(f"ROG Deck {__version__} -> http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
    finally:
        server.server_close()
    return 0

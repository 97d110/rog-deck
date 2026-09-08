"""Reactive per-key ripple: a water-drop wave from whichever key you press.

Each keypress spawns a ripple at that key's physical position. A ripple is a
set of concentric rings expanding outward; the leading ring is brightest and
each one behind it dimmer, so the wave reads as a drop hitting water. Ripples
composite by taking the brightest contribution per LED, which is what makes a
typed word light the whole board and then settle.

Privacy: to know where a ripple starts, this reads key events from
/dev/input/event*. It uses only the key's position, keeps no history, writes
nothing to disk, and sends nothing off the machine. It is nevertheless a
process that sees your keystrokes - run it only if you are happy with that.
"""

from __future__ import annotations

import argparse
import math
import os
import select
import signal
import struct
import sys
import time
from dataclasses import dataclass, field

from .keyboard_layout import (KEYCODE_TO_KEY, Led, load_leds,
                              typing_keyboards)

# struct input_event: timeval (2x long) + type + code + value
EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
EV_KEY = 0x01

PACKET_COUNT = 11
PACKET_SIZE = 64


@dataclass
class Ripple:
    x: float
    y: float
    born: float
    hue_shift: float = 0.0


@dataclass
class Settings:
    rings: int = 4
    speed: float = 9.0          # key-units per second
    spacing: float = 1.15       # gap between rings, key-units
    thickness: float = 0.62     # half-width of a ring band
    fade: float = 1.30          # seconds for a ripple to fade out
    fps: float = 30.0
    colour: tuple[int, int, int] = (60, 170, 255)
    base: float = 0.02          # faint idle glow so the board is not black
    ring_levels: tuple[float, ...] = (1.0, 0.55, 0.3, 0.15)


def build_packets() -> list[bytearray]:
    """11 HID packets with the headers rog-aura's per-key mode expects."""
    packets = []
    for group in range(PACKET_COUNT):
        p = bytearray(PACKET_SIZE)
        p[0] = 0x5D                       # report id
        p[1] = 0xBC                       # custom mode (0xB3 = builtin)
        p[2] = 0x00
        p[3] = 0x01
        p[4] = 0x01
        p[5] = 0x01
        p[6] = group << 4                 # key group
        p[7] = 0x08 if group == PACKET_COUNT - 1 else 0x10
        p[8] = 0x00
        packets.append(p)
    return packets


class AuraWriter:
    """Sends frames through asusd, which owns the device."""

    def __init__(self) -> None:
        import dbus  # imported lazily so --dry-run works without a bus

        self._dbus = dbus
        bus = dbus.SystemBus()
        obj = bus.get_object("xyz.ljones.Asusd", "/xyz/ljones/aura/19b6_2_1")
        self._aura = dbus.Interface(obj, "xyz.ljones.Aura")
        self._props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")

    def led_mode(self) -> int:
        try:
            return int(self._props.Get("xyz.ljones.Aura", "LedMode"))
        except Exception:
            return -1

    def set_led_mode(self, mode: int) -> None:
        self._props.Set("xyz.ljones.Aura", "LedMode", self._dbus.UInt32(mode))

    def brightness(self) -> int:
        try:
            return int(self._props.Get("xyz.ljones.Aura", "Brightness"))
        except Exception:
            return -1

    def set_brightness(self, level: int) -> None:
        self._props.Set("xyz.ljones.Aura", "Brightness",
                        self._dbus.UInt32(level))

    def send(self, packets: list[bytearray]) -> None:
        # ByteArray subclasses bytes and marshals straight to 'ay', which is
        # ~40x cheaper than building a dbus.Byte per element. The remaining
        # cost is asusd's USB write, measured at ~33ms for the 11 packets, so
        # roughly 30fps is the hardware ceiling here - not a Python limit.
        dbus = self._dbus
        payload = dbus.Array(
            [dbus.ByteArray(bytes(p)) for p in packets], signature="ay")
        self._aura.DirectAddressingRaw(payload)


class RippleEngine:
    def __init__(self, leds: list[Led], width: float, height: float,
                 settings: Settings) -> None:
        self.leds = leds
        self.settings = settings
        self.ripples: list[Ripple] = []
        # A ripple is done once its trailing ring has left the board.
        self.reach = math.hypot(width, height) + settings.rings * settings.spacing
        self.max_age = self.reach / settings.speed + settings.fade

    def spawn(self, key: str) -> None:
        hits = [l for l in self.leds if l.key == key]
        if not hits:
            return
        # Wide keys have several LEDs; start from their midpoint.
        x = sum(l.x for l in hits) / len(hits)
        y = sum(l.y for l in hits) / len(hits)
        self.ripples.append(Ripple(x=x, y=y, born=time.monotonic()))

    def intensity(self, led: Led, now: float) -> float:
        s = self.settings
        best = s.base
        for ripple in self.ripples:
            age = now - ripple.born
            radius = age * s.speed
            distance = math.hypot(led.x - ripple.x, led.y - ripple.y)

            # Envelope: ripples ease out over the last `fade` seconds of life.
            remaining = self.max_age - age
            envelope = 1.0 if remaining > s.fade else max(0.0, remaining / s.fade)
            if envelope <= 0.0:
                continue

            for index in range(s.rings):
                centre = radius - index * s.spacing
                if centre < 0:
                    break
                if abs(distance - centre) <= s.thickness:
                    level = s.ring_levels[min(index, len(s.ring_levels) - 1)]
                    # Soften the band edges so rings look round, not blocky.
                    edge = 1.0 - (abs(distance - centre) / s.thickness) ** 2
                    best = max(best, level * edge * envelope)
        return min(1.0, best)

    def render(self, packets: list[bytearray]) -> bool:
        now = time.monotonic()
        self.ripples = [r for r in self.ripples if now - r.born < self.max_age]

        r0, g0, b0 = self.settings.colour
        lit = False
        for led in self.leds:
            value = self.intensity(led, now)
            if value > self.settings.base:
                lit = True
            base = led.packet
            off = led.offset
            packets[base][off] = int(r0 * value)
            packets[base][off + 1] = int(g0 * value)
            packets[base][off + 2] = int(b0 * value)
        return lit or bool(self.ripples)


def open_keyboards() -> list[tuple[int, str]]:
    """Every readable input device that reports keyboard keys."""
    found = []
    for path in sorted(os.listdir("/dev/input")):
        if not path.startswith("event"):
            continue
        full = f"/dev/input/{path}"
        try:
            fd = os.open(full, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        found.append((fd, full))
    return found


class _Stop(Exception):
    """Raised from a SIGTERM handler so the restore path still runs."""


def _install_signal_handlers() -> None:
    # systemd sends SIGTERM on `stop`; Python's default action exits without
    # unwinding, which would leave the keyboard stuck in direct mode showing
    # the last frame we sent. Turn it into an exception instead.
    def raise_stop(_signum, _frame):
        raise _Stop()

    signal.signal(signal.SIGTERM, raise_stop)
    signal.signal(signal.SIGHUP, raise_stop)


def run(settings: Settings, dry_run: bool = False, ensure_brightness: bool = True) -> int:
    leds, width, height = load_leds()
    if not leds:
        print("This machine has no per-key layout available (needs a PerKey "
              "board and rog-control-center's layout files).", file=sys.stderr)
        return 1
    print(f"{len(leds)} LEDs, board {width:.1f}x{height:.1f} key-units")

    engine = RippleEngine(leds, width, height, settings)
    packets = build_packets()

    writer = None
    previous_mode = -1
    previous_brightness = -1
    if not dry_run:
        try:
            writer = AuraWriter()
        except Exception as exc:
            print(f"cannot reach asusd: {exc}", file=sys.stderr)
            return 1
        previous_mode = writer.led_mode()
        previous_brightness = writer.brightness()
        if ensure_brightness and writer.brightness() == 0:
            print("keyboard brightness was off; turning it up")
            try:
                writer.set_brightness(2)
            except Exception:
                print("could not raise brightness; run: asusctl leds set med")

    wanted = set(typing_keyboards())
    devices = [(fd, path) for fd, path in open_keyboards() if path in wanted]
    # Close anything we opened but will not read.
    for fd, path in open_keyboards():
        if path not in wanted:
            os.close(fd)
    if not devices:
        print("no readable keyboard device; are you in the 'input' group?",
              file=sys.stderr)
        return 1
    print("reading: " + ", ".join(p for _, p in devices))

    _install_signal_handlers()

    poller = select.poll()
    for fd, _ in devices:
        poller.register(fd, select.POLLIN)

    interval = 1.0 / settings.fps
    idle_frames = 0
    try:
        while True:
            start = time.monotonic()
            for fd, _ in poller.poll(0):
                try:
                    data = os.read(fd, EVENT_SIZE * 64)
                except OSError:
                    continue
                for chunk in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    _, _, etype, code, value = struct.unpack_from(
                        EVENT_FORMAT, data, chunk)
                    # Only key-down, and only the position is used.
                    if etype == EV_KEY and value == 1:
                        key = KEYCODE_TO_KEY.get(code)
                        if key:
                            engine.spawn(key)

            active = engine.render(packets)
            if active:
                idle_frames = 0
            else:
                idle_frames += 1

            # When nothing is animating, stop hammering the EC but keep one
            # frame going out occasionally so the idle glow stays applied.
            if active or idle_frames % 30 == 1:
                if writer is not None:
                    try:
                        writer.send(packets)
                    except Exception as exc:
                        print(f"send failed: {exc}", file=sys.stderr)
                        time.sleep(0.5)

            elapsed = time.monotonic() - start
            time.sleep(max(0.0, interval - elapsed))
    except (KeyboardInterrupt, _Stop):
        print("stopping", flush=True)
    finally:
        # Hand the keyboard back the way we found it: direct mode would
        # otherwise leave it frozen on the last frame we sent.
        if writer is not None:
            try:
                if previous_mode >= 0:
                    writer.set_led_mode(previous_mode)
                if previous_brightness >= 0:
                    writer.set_brightness(previous_brightness)
            except Exception:
                os.system("asusctl aura effect rainbow-cycle >/dev/null 2>&1")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="rog-deck-ripple",
                                description="Reactive per-key ripple effect")
    p.add_argument("--speed", type=float, default=9.0, help="ring speed, key-units/sec")
    p.add_argument("--rings", type=int, default=4, help="number of rings")
    p.add_argument("--spacing", type=float, default=1.15, help="gap between rings")
    p.add_argument("--thickness", type=float, default=0.62, help="ring half-width")
    p.add_argument("--fade", type=float, default=1.3, help="fade-out seconds")
    p.add_argument("--fps", type=float, default=30.0,
               help="frames/sec; ~30 is the EC ceiling")
    p.add_argument("--colour", default="3caaff", help="RRGGBB")
    p.add_argument("--base", type=float, default=0.02, help="idle glow 0..1")
    p.add_argument("--dry-run", action="store_true",
                   help="compute frames without touching the keyboard")
    args = p.parse_args(argv)

    raw = args.colour.lstrip("#")
    colour = tuple(int(raw[i:i + 2], 16) for i in (0, 2, 4))

    settings = Settings(rings=args.rings, speed=args.speed, spacing=args.spacing,
                        thickness=args.thickness, fade=args.fade, fps=args.fps,
                        colour=colour, base=args.base)
    return run(settings, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())

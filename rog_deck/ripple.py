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

from . import ripple_config
from .keyboard_layout import (BTN_LEFT, KEYCODE_TO_KEY, Led, load_leds,
                              touchpads, typing_keyboards)

# struct input_event: timeval (2x long) + type + code + value
EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
EV_KEY = 0x01

PACKET_COUNT = 11
PACKET_SIZE = 64

# The keyboard's own brightness level, which the Fn keys change. Using it as
# the effect's ceiling means the hardware shortcuts control the ripple too,
# instead of the app keeping a second, competing brightness.
BACKLIGHT = "/sys/class/leds/asus::kbd_backlight"


def hardware_brightness() -> float | None:
    """Backlight level as 0..1, or None when it cannot be read."""
    try:
        with open(f"{BACKLIGHT}/brightness") as fh:
            level = int(fh.read().strip())
        with open(f"{BACKLIGHT}/max_brightness") as fh:
            top = int(fh.read().strip())
    except (OSError, ValueError):
        return None
    if top <= 0:
        return None
    return max(0.0, min(1.0, level / top))


@dataclass
class Ripple:
    x: float
    y: float
    born: float
    # LED indices this wavefront has already lit. A key is latched once, then
    # decays; without this it would be re-lit by every ring that swept over
    # it, which is what made the original version flicker.
    crossed: set[int] = field(default_factory=set)


@dataclass
class Settings:
    speed: float = 9.0          # wavefront speed, key-units per second
    decay: float = 0.45         # seconds for a key to fade to ~37%
    steps: int = 0              # 0 = smooth; N = quantise the trail into N levels
    fps: float = 30.0
    colour: tuple[int, int, int] = (60, 170, 255)
    brightness: float = 1.0     # ceiling applied to the whole effect, 0..1
    # No idle glow by default: a permanent floor meant every key sat faintly
    # lit forever, which read as "some keys are stuck on".
    base: float = 0.0
    # The underside bar is one wide zone per side, so treating it like a key
    # makes it strobe on every keystroke. It holds instead, and only starts
    # fading once the keys have gone dark.
    lightbar_decay: float = 0.9


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
    """Latch-and-decay ripples.

    The wavefront expands at `speed`; the first time it reaches a key that key
    is latched to full brightness, and from then on it only decays. That gives
    each key one clean rise and a smooth fade.

    The earlier version instead lit a key whenever it fell inside one of four
    expanding ring bands. Because the bands are separated by gaps, a single
    key was lit, dimmed, lit again and dimmed again as the rings swept past -
    measured as brightness rising 8 separate times on one keypress, which read
    as flicker. The multi-level "rings" look survives here as a *spatial*
    gradient: keys further out were latched later, so they are brighter than
    the ones behind them.
    """

    def __init__(self, leds: list[Led], width: float, height: float,
                 settings: Settings) -> None:
        self.leds = leds
        self.settings = settings
        self.ripples: list[Ripple] = []
        self.levels = [0.0] * len(leds)
        self.is_bar = [led.kind == "lightbar" for led in leds]
        self.key_indices = [i for i, bar in enumerate(self.is_bar) if not bar]
        self.bar_indices = [i for i, bar in enumerate(self.is_bar) if bar]
        self.reach = math.hypot(width, height)
        self.max_age = self.reach / settings.speed
        self._last = time.monotonic()
        # Distances are recomputed per ripple, but the LED coordinates are
        # fixed, so keep them in flat lists for a tighter inner loop.
        self._xs = [l.x for l in leds]
        self._ys = [l.y for l in leds]

    def spawn(self, key: str) -> None:
        hits = [l for l in self.leds if l.key == key]
        if not hits:
            return
        x = sum(l.x for l in hits) / len(hits)
        y = sum(l.y for l in hits) / len(hits)
        self.ripples.append(Ripple(x=x, y=y, born=time.monotonic()))

    def _advance(self, now: float) -> None:
        s = self.settings
        dt = max(0.0, now - self._last)
        self._last = now

        # Exponential decay: every key heads toward zero at the same rate, so
        # brightness is monotonic once latched.
        if dt > 0 and s.decay > 0:
            factor = math.exp(-dt / s.decay)
            for i in self.key_indices:
                level = self.levels[i]
                if level > 0.0:
                    self.levels[i] = level * factor if level * factor > 0.004 else 0.0

            # Hold the bar while any key is still lit, so it does not stutter
            # along with individual keystrokes; fade it only once the board is
            # dark, and more slowly than the keys.
            keys_lit = any(self.levels[i] > 0.02 for i in self.key_indices)
            if not keys_lit and s.lightbar_decay > 0:
                bar_factor = math.exp(-dt / s.lightbar_decay)
                for i in self.bar_indices:
                    level = self.levels[i]
                    if level > 0.0:
                        self.levels[i] = (level * bar_factor
                                          if level * bar_factor > 0.004 else 0.0)

        alive = []
        for ripple in self.ripples:
            radius = (now - ripple.born) * s.speed
            crossed = ripple.crossed
            for i in range(len(self.leds)):
                if i in crossed:
                    continue
                dx = self._xs[i] - ripple.x
                dy = self._ys[i] - ripple.y
                if dx * dx + dy * dy <= radius * radius:
                    crossed.add(i)
                    self.levels[i] = 1.0
            # Retire once the front has left the board, or lit everything.
            if radius <= self.reach and len(crossed) < len(self.leds):
                alive.append(ripple)
        self.ripples = alive

    def _shape(self, level: float) -> float:
        s = self.settings
        if s.steps > 0 and level > 0.0:
            # Quantise the trail into N visible bands - the "4 level rings"
            # look, but monotonic, so it steps down instead of flickering.
            level = math.ceil(level * s.steps) / s.steps
        return min(1.0, max(s.base, level) * s.brightness)

    def render(self, packets: list[bytearray]) -> bool:
        self._advance(time.monotonic())
        r0, g0, b0 = self.settings.colour
        active = bool(self.ripples)
        for index, led in enumerate(self.leds):
            value = self._shape(self.levels[index])
            if self.levels[index] > 0.0:
                active = True
            off = led.offset
            packet = packets[led.packet]
            packet[off] = int(r0 * value)
            packet[off + 1] = int(g0 * value)
            packet[off + 2] = int(b0 * value)
        return active

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

    def apply_stored(target: Settings) -> None:
        stored = ripple_config.load()
        target.colour = ripple_config.rgb(stored["colour"])
        # The keyboard's own level drives the effect, so the Fn brightness
        # keys scale it. A level of 0 is not used as a ceiling, though: on
        # boards where the backlight cannot be raised by software that would
        # render the effect permanently invisible with nothing to show why.
        level = hardware_brightness()
        target.brightness = level if level else stored["brightness"]
        target.speed = stored["speed"]
        target.decay = stored["decay"]
        target.steps = stored["steps"]
        target.base = stored["base"]

    apply_stored(settings)
    config_seen = ripple_config.mtime()

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

    pads = set(touchpads())
    wanted = set(typing_keyboards()) | pads
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
    if pads:
        print("trackpad clicks ripple from the spacebar: " + ", ".join(sorted(pads)))
    pad_fds = {fd for fd, path in devices if path in pads}

    _install_signal_handlers()

    poller = select.poll()
    for fd, _ in devices:
        poller.register(fd, select.POLLIN)

    interval = 1.0 / settings.fps
    idle_frames = 0
    try:
        while True:
            start = time.monotonic()

            # Cheap stat(); lets either UI recolour the effect live.
            stamp = ripple_config.mtime()
            level = hardware_brightness()
            if stamp != config_seen or (level
                                        and abs(level - settings.brightness) > 0.001):
                config_seen = stamp
                apply_stored(settings)
                engine.max_age = engine.reach / max(0.1, settings.speed)
                print(f"settings reloaded: colour={settings.colour} "
                      f"brightness={settings.brightness}", flush=True)
            for fd, _ in poller.poll(0):
                try:
                    data = os.read(fd, EVENT_SIZE * 64)
                except OSError:
                    continue
                is_pad = fd in pad_fds
                for chunk in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    _, _, etype, code, value = struct.unpack_from(
                        EVENT_FORMAT, data, chunk)
                    # Only key-down, and only the position is used.
                    if etype != EV_KEY or value != 1:
                        continue
                    if is_pad:
                        if code == BTN_LEFT:
                            engine.spawn("Spacebar")
                        continue
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
    p.add_argument("--speed", type=float, default=9.0,
                   help="wavefront speed, key-units/sec")
    p.add_argument("--decay", type=float, default=0.45,
                   help="seconds for a lit key to fade")
    p.add_argument("--steps", type=int, default=0,
                   help="quantise the trail into N brightness bands (0 = smooth)")
    p.add_argument("--fps", type=float, default=30.0,
                   help="frames/sec; ~30 is the EC ceiling")
    p.add_argument("--colour", default="3caaff", help="RRGGBB")
    p.add_argument("--brightness", type=float, default=1.0,
                   help="overall ceiling, 0..1")
    p.add_argument("--base", type=float, default=0.02, help="idle glow 0..1")
    p.add_argument("--dry-run", action="store_true",
                   help="compute frames without touching the keyboard")
    args = p.parse_args(argv)

    raw = args.colour.lstrip("#")
    colour = tuple(int(raw[i:i + 2], 16) for i in (0, 2, 4))

    settings = Settings(speed=args.speed, decay=args.decay, steps=args.steps,
                        fps=args.fps, colour=colour,
                        brightness=args.brightness, base=args.base)

    # An explicit flag is a deliberate one-off, so persist it as the new
    # stored value rather than having the file immediately overwrite it.
    given = {}
    for name in ("speed", "decay", "steps", "brightness", "base"):
        if getattr(args, name) != p.get_default(name):
            given[name] = getattr(args, name)
    if args.colour != p.get_default("colour"):
        given["colour"] = args.colour
    if given:
        ripple_config.save(given)
    return run(settings, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())

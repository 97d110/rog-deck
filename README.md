# ROG Deck

An Armoury Crate replacement for Linux, as a native Omarchy app.

ASUS ships no control software for Linux, and `rog-control-center` leaves most
of the interesting firmware knobs untouched. ROG Deck exposes them: per-profile
fan curves you can drag, CPU power limits, GPU MUX and power, battery charge
care, keyboard Aura, the lid Slash light bar, the trackpad NumberPad, and a
reactive per-key ripple effect.

![ROG Deck](docs/screenshot.png)

## What it looks like

It is a Quickshell plugin, summoned like the command palette, and it is
**assembled from the Omarchy shell's own component library** rather than
restyled to resemble it:

| Piece | From |
| --- | --- |
| Popup surface, key handling | `Panel`, `PanelKeyCatcher`, `BorderSurface` |
| Section labels and rules | `PanelSectionHeader`, `PanelSeparator` |
| Sliders and switches | `PanelSlider`, `Toggle` |
| Every colour | `Color.menu.*` in `qs.Commons` |
| Every spacing, border, font size | `Style` in `qs.Commons` |

Because those are the same objects the Wi-Fi and Bluetooth panels use, it
re-themes with `omarchy theme set` and honours the spacing and font scale you
have configured — no palette of its own to drift out of step.

## Install

```bash
git clone https://github.com/97d110/rog-deck ~/.local/src/rog-deck
cd ~/.local/src/rog-deck
./install.sh
```

Then open it:

```bash
omarchy-shell shell summon rog-deck '{}'
```

…or launch **ROG Deck** from your app menu, or bind it:

```lua
o.bind("SUPER + SHIFT + R", "ROG Deck", "omarchy-shell -q shell summon rog-deck {}")
```

Remove it again with `./uninstall.sh`. Neither script changes hardware settings.

## Features

- **Performance profiles** — Quiet / Balanced / Performance. The firmware
  re-scopes every power limit per profile, so the app re-reads them on switch.
  It also surfaces asusd's separate AC and battery profiles, which otherwise
  look like the machine changing its own settings when you unplug.
- **Power & thermals** — `ppt_pl1_spl`, `ppt_pl2_sppt`, `ppt_pl3_fppt`.
- **Graphics** — `supergfxctl` mode, GPU MUX, dGPU enable, board power,
  dynamic boost, thermal target.
- **Fan curves** — drag the eight firmware points per fan, with a live marker
  showing the current temperature.
- **Battery** — charge limit and live status.
- **Lighting** — Aura brightness and all twelve keyboard effects. Each effect
  only sends the arguments it accepts, because `asusctl` hard-errors when
  handed one it does not support (a colour on `rainbow-cycle` is a failure,
  not a no-op).
- **Slash lid light bar** — on/off, brightness, and all sixteen animations
  including the classic `Loading` sweep.
- **NumberPad** — a switch for `asus-numberpad-driver`, plus hold-time and
  auto-off tuning.
- **Reactive keyboard ripple** — see below.
- **Sensors with context** — every reading is a gauge showing where the value
  sits between idle and that part's own ceiling, so you can tell "warm" from
  "about to throttle". Ceilings come from the hardware where it publishes them
  (NVMe `temp1_crit`, the firmware's `nv_temp_target`, nvidia's power limit)
  and are marked `(est)` where they had to be estimated.

Controls are generated from `/sys/class/firmware-attributes/asus-armoury`,
which is self-describing (type, range, defaults, enum values). Anything your
firmware exposes shows up, so this is not hard-coded to one laptop model.

## Architecture

```
omarchy-plugin/     the app - Quickshell/QML, the only user interface
rog_deck/           the service - owns every privileged path
```

The service reads sysfs (world-readable) and hands every privileged write to
`asusd` over D-Bus via `asusctl`, which does its own authorization. **Nothing
here runs as root**: each knob under `/sys` is `root:root 0644`, and the
service deliberately holds no privileges of its own.

The app talks to the service over JSON on `127.0.0.1:8737`. That is local IPC,
not a website — there is no web UI, and `/` returns 404. Binding it anywhere
but loopback is opt-in via `--host` and prints a warning, because the API
changes hardware state and has no authentication.

Keeping the hardware layer in Python is deliberate: the ripple daemon needs
D-Bus and evdev, and the firmware/fan-curve/aura logic is tested there.

| Area | Read from | Written via |
| --- | --- | --- |
| Firmware attributes | `/sys/class/firmware-attributes/asus-armoury` | `asusctl armoury set` |
| Platform profile | `/sys/firmware/acpi/platform_profile` | `asusctl profile set` |
| Fan curves | `asusctl fan-curve` | `asusctl fan-curve` |
| Battery limit | `/sys/class/power_supply/BAT*` | `asusctl battery limit` |
| Aura / Slash | `asusctl leds`, `asusctl slash --list` | `asusctl aura`, `asusctl slash` |
| GPU mode | `supergfxctl -g` | `supergfxctl -m` |
| Sensors | `/sys/class/hwmon`, `nvidia-smi` | — |
| NumberPad | driver ini file | driver ini file |
| Per-key ripple | — | `DirectAddressingRaw` on asusd |

## Reactive keyboard ripple (optional, off by default)

On a per-key board, `rog-deck-ripple` draws a water-drop wave from whichever
key you press: the wavefront latches each key to full brightness as it arrives
and the key then fades, so a typed word lights the whole board and settles. A
second wave re-latches a key, restarting its fade.

```bash
rog-deck-ripple                      # try it in the foreground
rog-deck-ripple --colour ff2d55 --speed 12
rog-deck-ripple --steps 4            # stepped trail instead of a smooth fade
rog-deck-ripple --dry-run            # compute frames, touch nothing
systemctl --user enable --now rog-deck-ripple
```

Colour, brightness, speed, fade and trail are also in the app, and the running
effect re-reads `~/.config/rog-deck/ripple.json` live.

**It reads your keystrokes.** A wave has to start at the key you pressed, so
the process reads key events from `/dev/input`. It uses only the key's
position, keeps no history, writes nothing to disk and sends nothing off the
machine — but it is a process that sees what you type, which is why it ships
installed-but-disabled. It reads only devices reporting a full alphabet, so
lid switches and power buttons are left alone, and it restores the keyboard
mode and brightness it found on exit, including on `systemctl --user stop`.

### How the per-key effect works

| Piece | Source |
| --- | --- |
| Is this board per-key? | `advanced_type` in `/usr/share/asusd/aura_support.ron` |
| LED → HID packet offset | baked table generated from asusctl's `rog-aura` |
| Physical key positions | rog-control-center's `layouts/<layout>_*.ron`, at runtime |
| Writing frames | `DirectAddressingRaw` — 11 × 64-byte HID packets |
| Which key was pressed | `/dev/input/event*`, filtered to real keyboards |

Frame rate is capped around **30fps**: asusd's USB write for the 11 packets
measures ~33ms, and that is the ceiling, not Python.

## Requirements

- Omarchy (for the app; the service runs anywhere) with `asusd` running
- Python 3.11+ — **no third-party Python packages**, standard library only
- Optional: `supergfxctl` for GPU mode switching, `nvidia-smi` for dGPU
  telemetry, `asus-numberpad-driver` for NumberPad control

## Hacking

Qt caches compiled QML per path, so after editing a plugin file run
`omarchy restart shell` — `rescanPlugins` alone will not recompile it.

## Known limits

- `asusctl` cannot read back Aura effects or Slash state, so those controls
  send an action rather than reflecting stored state. Everything else shows
  real hardware state.
- `charge_mode` is reported by firmware but rejected on write on some boards.
- Switching the GPU MUX needs a reboot; switching `supergfxctl` modes normally
  ends your session.
- asusd will not answer aura property reads while the ripple is streaming
  frames (`Aura control couldn't lock self`); reads via `asusctl` are fine.

## Tested on

ROG Strix G16 (G614FR) — Ryzen 9 9955HX, RTX 5070 Ti Laptop, Omarchy /
Hyprland, kernel 7.1, asusctl 6.3.8.

Reports from other ROG models welcome.

## Licence

MIT

"""Live telemetry: fan speeds, temperatures, power draw.

hwmon indices are not stable across boots, so devices are located by their
`name` file rather than by a hard-coded hwmonN path.
"""

from __future__ import annotations

import glob
import os
import subprocess
import time
from typing import Any

_HWMON_ROOT = "/sys/class/hwmon"

# nvidia-smi costs ~100ms, which is far too slow to sit inside a 1Hz poll
# loop serving several clients, so its result is cached briefly.
_NVIDIA_TTL = 2.0
_nvidia_cache: tuple[float, dict[str, Any] | None] = (0.0, None)


def _read_int(path: str) -> int | None:
    try:
        with open(path) as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return None


def _read_str(path: str) -> str | None:
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None


# Ranges attached to each reading so the UI can place a value between "fine"
# and "too hot" without the frontend hard-coding thermal knowledge.
#
# Real published limits are used wherever the hardware exposes them; the rest
# are documented defaults, and every range says which it is via `source` so
# the UI can be honest about it.
CPU_TJMAX = 95.0        # Ryzen 9 9955HX; k10temp publishes no crit/max
BOARD_CRIT = 90.0
FAN_CEILING = 6500.0    # observed ceiling on this chassis under full load

_fan_seen_max = 0.0


def _range(minimum, warn, crit, maximum, source):
    return {"min": minimum, "warn": warn, "crit": crit,
            "max": maximum, "source": source}


def _temp_range(kind: str, chip_path: str) -> dict:
    """Prefer limits the chip publishes; fall back to documented defaults."""
    published_max = _read_int(f"{chip_path}_max")
    published_crit = _read_int(f"{chip_path}_crit")
    if published_max and published_crit:
        return _range(20.0, round(published_max / 1000, 1),
                      round(published_crit / 1000, 1),
                      round(published_crit / 1000, 1) + 5, "hardware")

    if kind == "cpu":
        return _range(20.0, CPU_TJMAX - 15, CPU_TJMAX, CPU_TJMAX, "default")
    if kind == "igpu":
        return _range(20.0, 80.0, 95.0, 95.0, "default")
    if kind == "ssd":
        # NVMe drives throttle around 80C; the per-drive Composite sensor
        # usually publishes real limits, but the extra sensors on the same
        # controller often do not.
        return _range(20.0, 70.0, 80.0, 85.0, "default")
    return _range(20.0, BOARD_CRIT - 15, BOARD_CRIT, BOARD_CRIT, "default")


def _dgpu_temp_range() -> dict:
    """nv_temp_target is the firmware's real throttle point for this laptop."""
    target = _read_int(
        "/sys/class/firmware-attributes/asus-armoury/attributes/"
        "nv_temp_target/current_value"
    )
    crit = float(target) if target else 87.0
    return _range(20.0, crit - 10, crit, crit, "hardware" if target else "default")


def _hwmon_by_name() -> dict[str, list[str]]:
    """Map hwmon name -> paths. Names are not unique (two nvme, two spd5118)."""
    found: dict[str, list[str]] = {}
    for path in sorted(glob.glob(f"{_HWMON_ROOT}/hwmon*")):
        name = _read_str(f"{path}/name")
        if name:
            found.setdefault(name, []).append(path)
    return found


def fans() -> list[dict[str, Any]]:
    devices = _hwmon_by_name()
    out = []
    for path in devices.get("asus", []):
        for entry in sorted(glob.glob(f"{path}/fan*_input")):
            index = os.path.basename(entry).split("_")[0]
            label = _read_str(f"{path}/{index}_label") or index
            rpm = _read_int(entry)
            if rpm is None:
                continue
            global _fan_seen_max
            _fan_seen_max = max(_fan_seen_max, float(rpm))
            out.append({
                "id": label,
                "label": label.replace("_", " ").replace("fan", "").strip() or label,
                "rpm": rpm,
                "range": _range(0.0, FAN_CEILING * 0.6, FAN_CEILING * 0.85,
                                max(FAN_CEILING, _fan_seen_max), "estimate"),
            })
    return out


def temperatures() -> list[dict[str, Any]]:
    devices = _hwmon_by_name()
    out: list[dict[str, Any]] = []

    def collect(chip: str, friendly: str, kind: str) -> None:
        paths = devices.get(chip, [])
        for chip_index, path in enumerate(paths):
            # Only disambiguate when the same chip appears more than once.
            suffix = f" {chip_index + 1}" if len(paths) > 1 else ""
            for entry in sorted(glob.glob(f"{path}/temp*_input")):
                index = os.path.basename(entry).split("_")[0]
                label = _read_str(f"{path}/{index}_label") or friendly
                milli = _read_int(entry)
                if milli is None:
                    continue
                name = friendly if label == friendly else f"{friendly}{suffix} {label}"
                out.append({
                    "id": f"{chip}{chip_index}:{index}",
                    "label": name,
                    "kind": kind,
                    "celsius": round(milli / 1000, 1),
                    "range": _temp_range(kind, f"{path}/{index}"),
                })

    collect("k10temp", "CPU", "cpu")
    collect("amdgpu", "iGPU", "igpu")
    collect("nvme", "SSD", "ssd")
    collect("acpitz", "Board", "board")
    return out


def _nvidia() -> dict[str, Any] | None:
    global _nvidia_cache
    now = time.monotonic()
    cached_at, cached = _nvidia_cache
    if now - cached_at < _NVIDIA_TTL:
        return cached

    result: dict[str, Any] | None = None
    try:
        proc = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=name,temperature.gpu,power.draw,utilization.gpu,"
                "clocks.sm,memory.used,memory.total,power.max_limit",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True, text=True, timeout=5, check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            parts = [p.strip() for p in proc.stdout.strip().splitlines()[0].split(",")]

            def num(value: str) -> float | None:
                try:
                    return float(value)
                except ValueError:
                    return None

            watt_ceiling = num(parts[7]) if len(parts) > 7 else None
            result = {
                "name": parts[0],
                "celsius": num(parts[1]),
                "watts": num(parts[2]),
                "temp_range": _dgpu_temp_range(),
                "power_range": _range(
                    0.0,
                    (watt_ceiling or 140.0) * 0.7,
                    (watt_ceiling or 140.0) * 0.95,
                    watt_ceiling or 140.0,
                    "hardware" if watt_ceiling else "default",
                ),
                "util": num(parts[3]),
                "clock_mhz": num(parts[4]),
                "vram_used_mb": num(parts[5]),
                "vram_total_mb": num(parts[6]),
            }
    except (OSError, subprocess.TimeoutExpired, IndexError):
        result = None

    # A powered-down dGPU makes nvidia-smi fail; keep the last good reading
    # rather than flickering the panel empty.
    if result is None and cached is not None:
        _nvidia_cache = (now, cached)
        return cached

    _nvidia_cache = (now, result)
    return result


def power() -> dict[str, Any]:
    devices = _hwmon_by_name()
    out: dict[str, Any] = {}

    for path in devices.get("amdgpu", []):
        micro = _read_int(f"{path}/power1_input")
        if micro is not None:
            out["igpu_watts"] = round(micro / 1_000_000, 1)
        break

    for path in devices.get("BAT0", []):
        micro = _read_int(f"{path}/power1_input")
        if micro is not None:
            out["battery_watts"] = round(micro / 1_000_000, 1)
        break

    for supply in sorted(glob.glob("/sys/class/power_supply/*")):
        if _read_str(f"{supply}/type") == "Mains":
            online = _read_int(f"{supply}/online")
            if online is not None:
                out["on_ac"] = online == 1
            break

    return out


def cpu_load() -> float | None:
    try:
        return round(os.getloadavg()[0], 2)
    except OSError:
        return None


def snapshot() -> dict[str, Any]:
    return {
        "timestamp": time.time(),
        "fans": fans(),
        "temperatures": temperatures(),
        "power": power(),
        "dgpu": _nvidia(),
        "load": cpu_load(),
    }

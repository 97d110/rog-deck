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
            out.append({
                "id": label,
                "label": label.replace("_", " ").replace("fan", "").strip() or label,
                "rpm": rpm,
            })
    return out


def temperatures() -> list[dict[str, Any]]:
    devices = _hwmon_by_name()
    out: list[dict[str, Any]] = []

    def collect(chip: str, friendly: str) -> None:
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
                    "celsius": round(milli / 1000, 1),
                })

    collect("k10temp", "CPU")
    collect("amdgpu", "iGPU")
    collect("nvme", "SSD")
    collect("acpitz", "Board")
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
                "clocks.sm,memory.used,memory.total",
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

            result = {
                "name": parts[0],
                "celsius": num(parts[1]),
                "watts": num(parts[2]),
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

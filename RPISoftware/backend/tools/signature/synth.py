"""Synthetic labelled air-node windows for training the shadow signature model.

Each window is 40 status documents 15 s apart (600 s), the shape the hub classifies.
Events are parametric curves with randomised timing, size and decay, plus sensor
noise and occasionally dropped channels. They encode the same assumptions as the
rules, so agreement between the two measures consistency, not real-world accuracy.
Stdlib only, so tests can run it without the train extra.
"""

from __future__ import annotations

import random

from app.analytics.signature.features import AirSnapshot, parse_snapshot

STEP_S = 15.0
SAMPLES = 40
END_S = (SAMPLES - 1) * STEP_S
CLASSES = ("normal", "steam", "cooking", "aerosol", "gas_leak", "smouldering_fire", "flaming_fire", "unknown")
SECTIONS = ("co", "gas", "particulate", "climate", "presence")
DROP_P = 0.03  # chance per window that a section is invalid for the whole window
_NOISE = {"co": 0.5, "gas": 15.0, "temp": 0.05, "rh": 0.3}

# key -> (amplitude, decay fraction); decay is how much of the rise is gone by the window's end
Amps = dict[str, tuple[float, float]]


def _event(rng: random.Random, label: str) -> tuple[Amps, float, float]:
    """(amplitudes, rise seconds, presence probability) for one event of `label`."""
    u = rng.uniform
    if label == "normal":
        return {}, 60.0, 0.5
    if label == "steam":
        pm, d = u(15, 80), u(0.0, 0.3)
        return ({"pm2_5": (pm, d), "pm10": (pm * u(1.8, 3.0), d), "pm1_0": (pm * u(0.2, 0.4), d),
                 "rh": (u(15, 35), d), "temp": (u(0.5, 3.0), 0.0)}, u(60, 200), 0.9)
    if label == "cooking":
        pm, d, rise = u(12, 80), u(0.35, 0.9), u(70, 200)
        return ({"pm2_5": (pm, d), "pm1_0": (pm * u(0.65, 0.9), d), "pm10": (pm * u(1.1, 1.4), d),
                 "temp": (u(0.6, min(5.0, rise * 1.8 / 60)), 0.0), "rh": (u(3.5, 11), 0.0),
                 "co": (u(0, 12), d)}, rise, 1.0)
    if label == "aerosol":
        pm, d = u(20, 150), u(0.6, 0.95)
        return ({"pm2_5": (pm, d), "pm1_0": (pm * u(0.5, 0.8), d), "pm10": (pm * u(1.2, 1.6), d)},
                u(10, 25), 0.8)
    if label == "gas_leak":
        return {"gas": (u(800, 2500), u(0.0, 0.2))}, u(120, 380), 0.3
    if label == "smouldering_fire":
        pm, d = u(20, 150), u(0.0, 0.3)
        return ({"pm2_5": (pm, d), "pm1_0": (pm * u(0.7, 0.9), d), "pm10": (pm * u(1.1, 1.3), d),
                 "co": (u(16, 60), d), "temp": (u(0, 1.5), 0.0), "rh": (u(0, 4), 0.0)}, u(200, 380), 0.3)
    if label == "flaming_fire":
        pm, d = u(20, 200), u(0.0, 0.3)
        return ({"pm2_5": (pm, d), "pm1_0": (pm * u(0.6, 0.8), d), "pm10": (pm * u(1.1, 1.4), d),
                 "co": (u(15, 80), d), "temp": (u(8, 25), 0.0), "rh": (-u(0, 10), 0.0)}, u(60, 150), 0.3)
    if label == "unknown":  # something changed that no signature explains
        if rng.random() < 0.5:
            return {"rh": (u(12, 30), 0.0)}, u(60, 300), 0.5
        return {"temp": (u(2.5, 6), 0.0)}, u(200, 380), 0.5
    raise ValueError(f"unknown class {label!r}")


def _curve(base: float, amp: float, t0: float, rise_s: float, decay: float, t: float) -> float:
    """base until t0, linear rise by amp over rise_s, then linear loss of decay x amp until the end."""
    if t <= t0:
        return base
    if t <= t0 + rise_s:
        return base + amp * (t - t0) / rise_s
    frac = min(1.0, (t - t0 - rise_s) / max(END_S - t0 - rise_s, STEP_S))
    return base + amp * (1.0 - decay * frac)


def _grade(value: float, warn: float, danger: float) -> str:
    return "danger" if value >= danger else "warning" if value >= warn else "ok"


def _doc(v: dict[str, float], present: bool, dropped: set[str]) -> dict:
    doc = {
        "co": {"ppm": round(v["co"], 1), "state": _grade(v["co"], 50, 100), "warn_ppm": 50, "danger_ppm": 100,
               "valid": True},
        "gas": {"adc": round(v["gas"]), "state": _grade(v["gas"], 1500, 2200), "warn_adc": 1500, "danger_adc": 2200},
        "particulate": {"pm1_0": round(v["pm1_0"]), "pm2_5": round(v["pm2_5"]), "pm10": round(v["pm10"]),
                        "state": _grade(v["pm2_5"], 35, 150), "warn_pm2_5": 35, "danger_pm2_5": 150,
                        "warn_pm10": 100, "danger_pm10": 250, "valid": True},
        "climate": {"temperature_c": round(v["temp"], 1), "humidity_percent": round(v["rh"], 1), "valid": True},
        "presence": {"detected": present, "valid": True},
    }
    for section in dropped:
        if section == "gas":
            doc["gas"]["state"] = "fault"  # gas has no `valid` flag
        else:
            doc[section]["valid"] = False
    return doc


def _window(rng: random.Random, label: str) -> list[AirSnapshot]:
    u = rng.uniform
    base = {"co": u(0, 8), "gas": u(400, 900), "pm2_5": u(2, 15), "temp": u(18, 26), "rh": u(30, 55)}
    base["pm1_0"] = base["pm2_5"] * u(0.5, 0.7)
    base["pm10"] = base["pm2_5"] * u(1.2, 1.6)
    amps, rise_s, presence_p = _event(rng, label)
    t0 = u(190, 260)
    rise_s = min(rise_s, END_S - STEP_S - t0)
    dropped = {s for s in SECTIONS if rng.random() < DROP_P}
    snaps = []
    for i in range(SAMPLES):
        t = i * STEP_S
        v = {}
        for key, b in base.items():
            amp, decay = amps.get(key, (0.0, 0.0))
            noise = _NOISE.get(key, 0.04 * b + 0.5)
            v[key] = max(0.0, _curve(b, amp, t0, rise_s, decay, t) + rng.gauss(0.0, noise))
        v["rh"] = min(v["rh"], 100.0)
        snaps.append(parse_snapshot(t, _doc(v, rng.random() < presence_p, dropped)))
    return snaps


def generate(seed: int, n_per_class: int) -> list[tuple[str, list[AirSnapshot]]]:
    rng = random.Random(seed)
    return [(label, _window(rng, label)) for label in CLASSES for _ in range(n_per_class)]

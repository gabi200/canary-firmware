"""Air-node windows for the signature classifier tests: one 600 s window (40 status
documents, 15 s apart) per scenario, built from the docs/HARDWARE.md air sample.
Events start after the first third of the window so the baseline stays clean."""

from __future__ import annotations

from collections.abc import Callable

from app.analytics.signature.features import AirSnapshot, parse_snapshot
from tests.hardware_docs import air_doc

STEP_S = 15.0
SAMPLES = 40

Curve = Callable[[float], float]


def ramp(a: float, b: float, t0: float = 200.0, t1: float = 350.0) -> Curve:
    def f(t: float) -> float:
        if t <= t0:
            return a
        if t >= t1:
            return b
        return a + (b - a) * (t - t0) / (t1 - t0)
    return f


def rise_fall(a: float, peak: float, t0: float, t_peak: float, end: float, t_end: float) -> Curve:
    def f(t: float) -> float:
        if t <= t0:
            return a
        if t <= t_peak:
            return a + (peak - a) * (t - t0) / (t_peak - t0)
        if t <= t_end:
            return peak + (end - peak) * (t - t_peak) / (t_end - t_peak)
        return end
    return f


BASE = {"co": 3.0, "gas": 640.0, "pm1_0": 4.0, "pm2_5": 7.0, "pm10": 9.0, "temp": 22.4, "rh": 41.5}

SCENARIOS: dict[str, dict] = {
    "normal": {},
    "steam": {"rh": ramp(41.5, 70), "pm2_5": ramp(7, 60), "pm10": ramp(9, 140), "pm1_0": ramp(4, 20),
              "temp": ramp(22.4, 24)},
    "cooking": {"pm2_5": rise_fall(7, 45, 200, 300, 20, 585), "pm1_0": rise_fall(4, 35, 200, 300, 14, 585),
                "pm10": rise_fall(9, 52, 200, 300, 25, 585), "temp": ramp(22.4, 25, 200, 300),
                "rh": ramp(41.5, 48, 200, 300), "co": ramp(3, 12, 200, 300)},
    "aerosol": {"pm2_5": rise_fall(7, 90, 200, 230, 15, 400), "pm1_0": rise_fall(4, 60, 200, 230, 10, 400),
                "pm10": rise_fall(9, 120, 200, 230, 20, 400)},
    "gas_leak": {"gas": ramp(640, 2000, 200, 450), "presence": False},
    "smouldering_fire": {"pm2_5": ramp(7, 80, 200, 500), "pm1_0": ramp(4, 60, 200, 500),
                         "pm10": ramp(9, 95, 200, 500), "co": ramp(3, 25, 200, 500),
                         "temp": ramp(22.4, 23.4, 200, 500), "rh": ramp(41.5, 42, 200, 500), "presence": False},
    "flaming_fire": {"temp": ramp(22.4, 35, 200, 320), "pm2_5": ramp(7, 120, 200, 320),
                     "pm1_0": ramp(4, 90, 200, 320), "pm10": ramp(9, 150, 200, 320),
                     "co": ramp(3, 30, 200, 320), "rh": ramp(41.5, 35, 200, 320), "presence": False},
    "humidity_only": {"rh": ramp(41.5, 62)},
}


def _grade(value: float, warn: float, danger: float) -> str:
    return "danger" if value >= danger else "warning" if value >= warn else "ok"


def scenario_docs(name: str, start_uptime_ms: int = 1_000_000) -> list[tuple[float, dict]]:
    spec = SCENARIOS[name]
    curves: dict[str, Curve] = {key: (lambda t, v=value: v) for key, value in BASE.items()}
    curves.update({key: f for key, f in spec.items() if key != "presence"})
    present = spec.get("presence", True)
    out = []
    for i in range(SAMPLES):
        t = i * STEP_S
        v = {key: round(f(t), 2) for key, f in curves.items()}
        doc = air_doc(
            uptime_ms=start_uptime_ms + int(t * 1000),
            co={"ppm": v["co"], "state": _grade(v["co"], 50, 100)},
            gas={"adc": v["gas"], "state": _grade(v["gas"], 1500, 2200)},
            particulate={"pm1_0": v["pm1_0"], "pm2_5": v["pm2_5"], "pm10": v["pm10"],
                         "state": _grade(v["pm2_5"], 35, 150)},
            climate={"temperature_c": v["temp"], "humidity_percent": v["rh"]},
            presence={"detected": present},
        )
        out.append((t, doc))
    return out


def scenario_snapshots(name: str) -> list[AirSnapshot]:
    return [parse_snapshot(t, doc) for t, doc in scenario_docs(name)]

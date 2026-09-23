"""Pure hazard-source triangulation.

Estimates the most probable origin of a gas/CO leak from a distributed sensor
array, using concentration gradients and time-of-first-detection ordering, with an
optional coarse airflow prior. No DB / no I/O — fully deterministic and unit-testable.

REALISTIC LIMITS (ARCHITECTURE.md section B.1): indoor triangulation is fundamentally
constrained by gas diffusion, HVAC mixing, and sparse sensors. With one sensor this
degrades to "the leak is in this zone" (no sub-zone resolution). Confidence is capped
well below 1.0 and should be read as a decision aid, never a guarantee. The estimate
is a weighted centroid biased toward the highest, earliest concentrations — it locates
the accumulation peak, which (absent strong airflow) is a good proxy for the source.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SensorPoint:
    device_id: str
    zone_id: str
    x: float
    y: float
    value: float
    baseline: float  # detection threshold for this sensor type
    detected_ts: float | None = None  # seconds; time of first threshold crossing


@dataclass
class Contributor:
    device_id: str
    zone_id: str
    value: float
    weight: float  # normalized 0..1


@dataclass
class TriangulationResult:
    source_x: float | None
    source_y: float | None
    source_zone_id: str | None
    confidence: float
    method: str
    n_contributors: int
    airflow_applied: bool = False
    contributors: list[Contributor] = field(default_factory=list)


_BASE_BY_COUNT = {1: 0.35, 2: 0.55, 3: 0.70}


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _building_diag(zones: dict[str, tuple[float, float]]) -> float:
    if not zones:
        return 1.0
    xs = [p[0] for p in zones.values()]
    ys = [p[1] for p in zones.values()]
    diag = math.hypot(max(xs) - min(xs), max(ys) - min(ys))
    return diag if diag > 0 else 1.0


def _nearest_zone(x: float, y: float, zones: dict[str, tuple[float, float]]) -> str | None:
    best: str | None = None
    best_d = math.inf
    for zid, (zx, zy) in zones.items():
        d = math.hypot(zx - x, zy - y)
        if d < best_d:
            best_d, best = d, zid
    return best


def triangulate(
    sensors: list[SensorPoint],
    zones: dict[str, tuple[float, float]],
    *,
    tau: float = 30.0,
    airflow: tuple[float, float] | None = None,
    airflow_factor: float = 0.5,
) -> TriangulationResult:
    """Estimate the hazard source from sensor readings.

    `sensors`: candidate sensors (of the relevant hazard type) with positions + values.
    `zones`: all building zones id -> (x, y), used for nearest-zone mapping + scale.
    `tau`: time-decay constant (s) for the time-of-first-detection weighting.
    `airflow`: optional (dx, dy) wind direction; if set, nudges the estimate UPWIND of
               the concentration peak (gas accumulates downwind of the source).
    """
    contributors_raw = [s for s in sensors if s.value >= s.baseline]
    k = len(contributors_raw)
    if k == 0:
        return TriangulationResult(None, None, None, 0.0, "insufficient_data", 0)

    ts_present = [s.detected_ts for s in contributors_raw if s.detected_ts is not None]
    t_first = min(ts_present) if ts_present else None

    weights: list[float] = []
    for s in contributors_raw:
        conc_w = max(s.value - s.baseline, 0.0) + 1e-6  # concentration above threshold
        if t_first is not None and s.detected_ts is not None:
            time_w = math.exp(-(s.detected_ts - t_first) / tau)
        else:
            time_w = 1.0
        weights.append(conc_w * time_w)

    total = sum(weights)
    sx = sum(w * s.x for w, s in zip(weights, contributors_raw)) / total
    sy = sum(w * s.y for w, s in zip(weights, contributors_raw)) / total

    method = "concentration_weighted_centroid"
    if t_first is not None:
        method += "+time"

    # weighted spread (rms distance from estimate) -> locality factor for confidence
    var = sum(w * ((s.x - sx) ** 2 + (s.y - sy) ** 2) for w, s in zip(weights, contributors_raw)) / total
    rms = math.sqrt(var)
    diag = _building_diag(zones)

    airflow_applied = False
    if airflow is not None:
        ax, ay = airflow
        norm = math.hypot(ax, ay)
        if norm > 0:
            # move upwind by a fraction of the spread (source is upwind of accumulation)
            sx -= (ax / norm) * airflow_factor * rms
            sy -= (ay / norm) * airflow_factor * rms
            airflow_applied = True
            method += "+airflow"

    source_zone = _nearest_zone(sx, sy, zones) if zones else contributors_raw[0].zone_id

    base = _BASE_BY_COUNT.get(k, 0.8)
    spread_norm = _clamp(rms / diag, 0.0, 1.0)
    locality = _clamp(1.0 - spread_norm, 0.3, 1.0)
    confidence = round(_clamp(base * locality, 0.0, 0.95), 3)

    contributors = [
        Contributor(device_id=s.device_id, zone_id=s.zone_id, value=s.value, weight=round(w / total, 3))
        for w, s in zip(weights, contributors_raw)
    ]
    contributors.sort(key=lambda c: c.weight, reverse=True)

    return TriangulationResult(
        source_x=round(sx, 2),
        source_y=round(sy, 2),
        source_zone_id=source_zone,
        confidence=confidence,
        method=method,
        n_contributors=k,
        airflow_applied=airflow_applied,
        contributors=contributors,
    )

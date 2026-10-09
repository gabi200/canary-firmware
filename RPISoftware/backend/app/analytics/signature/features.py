"""Window features for the hazard signature classifier.

Turns an air node's recent status documents (the node_status payloads, docs/HARDWARE.md
section 1) into a fixed, named feature vector. Pure: no DB, no I/O. A feature that
cannot be computed is None, never 0, so a missing sensor stays distinct from a flat
one. The same vector feeds the rules and the shadow model.
"""

from __future__ import annotations

import statistics
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, fields

from app.analytics.environment import finite_number

CHANNELS = ("co", "gas", "pm2_5", "pm1_0", "pm10")
# channel -> (document section, value key, warn-threshold key); PM1 has no threshold of its own
_SOURCES = {
    "co": ("co", "ppm", "warn_ppm"),
    "gas": ("gas", "adc", "warn_adc"),
    "pm2_5": ("particulate", "pm2_5", "warn_pm2_5"),
    "pm1_0": ("particulate", "pm1_0", "warn_pm2_5"),
    "pm10": ("particulate", "pm10", "warn_pm10"),
}
_UNUSABLE_STATES = frozenset({"warmup", "fault"})
_MIN_CHANNEL_POINTS = 3
TEMP_RATE_SPAN_S = 60.0
# Onset starts at the last sample within this fraction of warn above the baseline.
ONSET_QUIET_FRACTION = 0.1
# Below this PM2.5 rise (in multiples of warn) the PM1 / PM10 shares are noise.
SHARE_MIN_RISE = 0.1


@dataclass(frozen=True)
class AirSnapshot:
    ts: float  # hub receipt time, epoch seconds
    values: Mapping[str, float]  # channel -> reading, usable channels only
    warn: Mapping[str, float]  # channel -> the device's warn threshold
    temperature_c: float | None
    humidity_percent: float | None
    presence: bool | None


@dataclass(frozen=True)
class SignatureFeatures:
    rise_co: float | None
    decay_co: float | None
    onset_s_co: float | None
    rise_gas: float | None
    decay_gas: float | None
    onset_s_gas: float | None
    rise_pm2_5: float | None
    decay_pm2_5: float | None
    onset_s_pm2_5: float | None
    rise_pm1_0: float | None
    decay_pm1_0: float | None
    onset_s_pm1_0: float | None
    rise_pm10: float | None
    decay_pm10: float | None
    onset_s_pm10: float | None
    rh_delta: float | None
    temp_delta: float | None
    temp_rate: float | None
    fine_share: float | None
    coarse_share: float | None
    presence_frac: float | None
    n_samples: float
    span_s: float

    def as_vector(self) -> list[float | None]:
        return [getattr(self, name) for name in FEATURE_NAMES]


FEATURE_NAMES: tuple[str, ...] = tuple(f.name for f in fields(SignatureFeatures))


@dataclass(frozen=True)
class _ChannelStats:
    rise: float
    decay: float
    onset_s: float
    delta: float  # peak - baseline, in the channel's own units


def _usable(obj: object) -> bool:
    if not isinstance(obj, Mapping):
        return False
    if obj.get("state") in _UNUSABLE_STATES:
        return False
    return "valid" not in obj or obj["valid"] is True  # gas has no `valid` flag


def parse_snapshot(ts: float, doc: object) -> AirSnapshot:
    """One status document as a snapshot; unusable channels are left out, never zeroed."""
    values: dict[str, float] = {}
    warn: dict[str, float] = {}
    temperature = humidity = None
    presence = None
    if isinstance(doc, Mapping):
        for channel, (section, key, warn_key) in _SOURCES.items():
            obj = doc.get(section)
            if not _usable(obj):
                continue
            value, threshold = finite_number(obj.get(key)), finite_number(obj.get(warn_key))
            if value is None or threshold is None or threshold <= 0:
                continue
            values[channel] = value
            warn[channel] = threshold
        climate = doc.get("climate")
        if _usable(climate):
            temperature = finite_number(climate.get("temperature_c"))
            humidity = finite_number(climate.get("humidity_percent"))
        detected = doc.get("presence")
        if _usable(detected) and isinstance(detected.get("detected"), bool):
            presence = detected["detected"]
    return AirSnapshot(ts, values, warn, temperature, humidity, presence)


def _baseline(values: Sequence[float]) -> float:
    """Median of the earliest third of the window (at least 2 samples)."""
    return statistics.median(values[: max(2, len(values) // 3)])


def _channel(points: Sequence[tuple[float, float]], warn: float) -> _ChannelStats | None:
    if len(points) < _MIN_CHANNEL_POINTS:
        return None
    values = [v for _, v in points]
    base = _baseline(values)
    i_peak = max(range(len(values)), key=values.__getitem__)  # first maximum
    peak, latest = values[i_peak], values[-1]
    delta = max(0.0, peak - base)
    decay = (peak - latest) / (peak - base) if peak > base else 0.0
    quiet = base + ONSET_QUIET_FRACTION * warn
    start = points[0][0]
    for t, v in points[: i_peak + 1]:
        if v <= quiet:
            start = t
    return _ChannelStats(rise=delta / warn, decay=decay, onset_s=points[i_peak][0] - start, delta=delta)


def _climb(values: Sequence[float]) -> float | None:
    if len(values) < _MIN_CHANNEL_POINTS:
        return None
    return max(values) - _baseline(values)


def _max_rise_within(points: Sequence[tuple[float, float]], span_s: float) -> float | None:
    """Largest increase between two samples at most `span_s` apart (zero-length spans skipped)."""
    if len(points) < 2:
        return None
    best = 0.0
    for i, (t_i, v_i) in enumerate(points):
        for t_j, v_j in points[i + 1:]:
            if t_j - t_i > span_s:
                break
            if t_j > t_i:
                best = max(best, v_j - v_i)
    return best


def extract_features(snapshots: Sequence[AirSnapshot]) -> SignatureFeatures:
    snaps = sorted(snapshots, key=lambda s: s.ts)
    out: dict[str, float | None] = {}
    deltas: dict[str, float | None] = {}
    for channel in CHANNELS:
        points = [(s.ts, s.values[channel]) for s in snaps if channel in s.values]
        warn = next((s.warn[channel] for s in reversed(snaps) if channel in s.warn), None)
        stats = _channel(points, warn) if warn else None
        out[f"rise_{channel}"] = stats.rise if stats else None
        out[f"decay_{channel}"] = stats.decay if stats else None
        out[f"onset_s_{channel}"] = stats.onset_s if stats else None
        deltas[channel] = stats.delta if stats else None

    temps = [(s.ts, s.temperature_c) for s in snaps if s.temperature_c is not None]
    out["rh_delta"] = _climb([s.humidity_percent for s in snaps if s.humidity_percent is not None])
    out["temp_delta"] = _climb([v for _, v in temps])
    out["temp_rate"] = _max_rise_within(temps, TEMP_RATE_SPAN_S)

    rise_pm = out["rise_pm2_5"]
    shares_ok = rise_pm is not None and rise_pm >= SHARE_MIN_RISE
    pm_delta = deltas["pm2_5"]
    out["fine_share"] = deltas["pm1_0"] / pm_delta if shares_ok and deltas["pm1_0"] is not None else None
    out["coarse_share"] = deltas["pm10"] / pm_delta if shares_ok and deltas["pm10"] is not None else None

    presence = [s.presence for s in snaps if s.presence is not None]
    out["presence_frac"] = sum(presence) / len(presence) if presence else None
    out["n_samples"] = float(len(snaps))
    out["span_s"] = snaps[-1].ts - snaps[0].ts if snaps else 0.0
    return SignatureFeatures(**out)

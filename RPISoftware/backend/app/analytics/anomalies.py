"""Pure sensor trust checks over caller-supplied, bounded history."""

from __future__ import annotations

import math
from dataclasses import dataclass
from statistics import median


@dataclass(frozen=True)
class AnomalySample:
    ts: float
    value: float
    valid: bool = True
    warmup: bool = False
    incident: bool = False


@dataclass(frozen=True)
class ChannelTrust:
    state: str
    reason: str
    sample_count: int
    input_age_seconds: float | None


def is_stale(*, last_seen_ts: float | None, now_ts: float, interval_s: float, multiplier: float = 3.0) -> bool:
    """Whether coverage has been absent for more than the allowed reporting intervals."""
    return last_seen_ts is None or now_ts - last_seen_ts > max(interval_s, 1.0) * multiplier


def _mad(values: list[float]) -> float:
    centre = median(values)
    return median(abs(value - centre) for value in values)


def _normalise(samples: list[AnomalySample]) -> list[AnomalySample]:
    unique: dict[tuple[float, float], AnomalySample] = {}
    for sample in samples:
        if sample.valid and not sample.warmup and not sample.incident and math.isfinite(sample.value):
            unique[(sample.ts, sample.value)] = sample
    return sorted(unique.values(), key=lambda sample: sample.ts)


def assess_channel(
    samples: list[AnomalySample],
    *,
    now_ts: float,
    interval_s: float,
    reference_cutoff_ts: float,
    stuck_limit_s: float | None = None,
    binary: bool = False,
) -> ChannelTrust:
    """Compare recent samples with a frozen pre-cutoff reference without discarding source data."""
    clean = _normalise(samples)
    age = max(0.0, now_ts - clean[-1].ts) if clean else None
    if not clean:
        return ChannelTrust("suspect", "insufficient_data", 0, None)

    reference = [sample.value for sample in clean if sample.ts < reference_cutoff_ts]
    recent = [sample for sample in clean if sample.ts >= reference_cutoff_ts]
    if len(recent) < 2:
        return ChannelTrust("suspect", "insufficient_data", len(clean), age)
    if binary:
        return ChannelTrust("ok", "ok", len(clean), age)

    stuck_for = stuck_limit_s if stuck_limit_s is not None else max(5 * interval_s, 60.0)
    if recent[-1].ts - recent[0].ts >= stuck_for and max(s.value for s in recent) == min(s.value for s in recent):
        return ChannelTrust("suspect", "stuck_channel", len(clean), age)
    if len(reference) < 5 or len(recent) < 3:
        return ChannelTrust("suspect", "insufficient_reference", len(clean), age)

    reference_noise = median(abs(b - a) for a, b in zip(reference, reference[1:]))
    recent_values = [sample.value for sample in recent]
    recent_noise = median(abs(b - a) for a, b in zip(recent_values, recent_values[1:]))
    scale = max(_mad(reference) * 1.4826, abs(median(reference)) * 0.01, 0.01)
    if recent_noise > max(reference_noise * 3.0, scale * 3.0):
        return ChannelTrust("suspect", "noise_rising", len(clean), age)
    if abs(median(recent_values) - median(reference)) > scale * 6.0:
        return ChannelTrust("suspect", "baseline_shift_cause_unknown", len(clean), age)
    return ChannelTrust("ok", "ok", len(clean), age)

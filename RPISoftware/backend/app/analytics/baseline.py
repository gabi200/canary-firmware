"""Pure "learned normal" per room: a frozen median / MAD reference per (zone, sensor type).

A reference is built once from a past window (REFERENCE_DAYS, ending GAP_DAYS ago) and then held
fixed: a slow leak or drift is not absorbed into "normal". Samples the node flagged (edge state
other than `normal`) and every incident window of the building are left out. Warm-up and invalid
channels never become readings in the first place (app.ingestion.hardware).

Hour-of-day buckets (building-local hour) are used only once the reference spans MIN_DAYS_FOR_HOURS
distinct days and a bucket has MIN_BUCKET_SAMPLES; otherwise one all-hours reference.

`assess()` gives a robust deviation (value - median) / (1.4826 * MAD), with a per-metric floor on
the spread. It is a heuristic score, not a probability. It is evidence for the fusion panel and
never replaces the absolute thresholds or touches the alarm path.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, tzinfo
from statistics import median

REFERENCE_DAYS = 14
GAP_DAYS = 1  # the last day is not in the reference: today's behaviour is what we compare
MIN_SAMPLES = 200
MIN_SPAN_S = 24 * 3600.0
MIN_DAYS_FOR_HOURS = 7
MIN_BUCKET_SAMPLES = 30
INCIDENT_PAD_BEFORE = timedelta(minutes=15)
INCIDENT_PAD_AFTER = timedelta(minutes=30)
UNUSUAL_SCORE = 3.0
MAD_K = 1.4826  # MAD -> standard deviation for normal data

# Baselines cover the continuous hazard channels. water_leak is binary: flat is normal.
METRICS = ("co", "combustible_gas", "particulate")
# The smallest spread a reference is allowed, in the reading's units: a quiet room has a MAD of
# almost 0 and would call every sensor tick "unusual".
SPREAD_FLOOR = {"co": 1.0, "combustible_gas": 20.0, "particulate": 3.0}

USUAL, UNUSUAL_HIGH, UNUSUAL_LOW, LEARNING, NO_RECENT = (
    "usual", "unusual_high", "unusual_low", "learning", "no_recent_data")
ALL_HOURS = -1


@dataclass(frozen=True)
class Sample:
    ts: datetime  # UTC
    value: float
    edge_state: str = "normal"


@dataclass(frozen=True)
class Reference:
    hour: int  # building-local hour, or ALL_HOURS
    median: float | None  # None: not enough samples yet
    mad: float | None
    n: int


@dataclass(frozen=True)
class Assessment:
    status: str
    score: float | None  # robust deviation; heuristic, not a probability
    reference: Reference | None


def reference_window(now: datetime) -> tuple[datetime, datetime]:
    end = now - timedelta(days=GAP_DAYS)
    return end - timedelta(days=REFERENCE_DAYS), end


def _excluded(ts: datetime, windows: list[tuple[datetime, datetime]]) -> bool:
    return any(start <= ts <= end for start, end in windows)


def incident_windows(spans: list[tuple[datetime, datetime | None]], now: datetime) -> list[tuple[datetime, datetime]]:
    """(opened, resolved or None while open) -> padded windows to leave out of a reference."""
    return [(o - INCIDENT_PAD_BEFORE, (r or now) + INCIDENT_PAD_AFTER) for o, r in spans]


def _mad(values: list[float], med: float) -> float:
    return median(abs(v - med) for v in values)


def build_references(samples: list[Sample], excluded: list[tuple[datetime, datetime]], tz: tzinfo) -> list[Reference]:
    """The references for one (zone, metric): one all-hours entry (median None while learning),
    plus hour buckets once there is enough history."""
    kept = [s for s in samples if s.edge_state == "normal" and not _excluded(s.ts, excluded)]
    if len(kept) < MIN_SAMPLES or (max(s.ts for s in kept) - min(s.ts for s in kept)).total_seconds() < MIN_SPAN_S:
        return [Reference(hour=ALL_HOURS, median=None, mad=None, n=len(kept))]
    values = [s.value for s in kept]
    med = median(values)
    out = [Reference(hour=ALL_HOURS, median=med, mad=_mad(values, med), n=len(values))]
    local = [(s.ts.astimezone(tz), s.value) for s in kept]
    if len({ts.date() for ts, _ in local}) >= MIN_DAYS_FOR_HOURS:
        for hour in range(24):
            bucket = [v for ts, v in local if ts.hour == hour]
            if len(bucket) >= MIN_BUCKET_SAMPLES:
                bmed = median(bucket)
                out.append(Reference(hour=hour, median=bmed, mad=_mad(bucket, bmed), n=len(bucket)))
    return out


def pick_reference(refs: list[Reference], local_hour: int) -> Reference | None:
    """The hour bucket when there is one, else the all-hours reference."""
    by_hour = {r.hour: r for r in refs}
    return by_hour.get(local_hour) or by_hour.get(ALL_HOURS)


def assess(metric: str, value: float | None, ref: Reference | None) -> Assessment:
    if ref is None or ref.median is None or ref.mad is None:
        return Assessment(status=LEARNING, score=None, reference=ref)
    if value is None:
        return Assessment(status=NO_RECENT, score=None, reference=ref)
    spread = max(MAD_K * ref.mad, SPREAD_FLOOR.get(metric, 1.0))
    score = (value - ref.median) / spread
    status = UNUSUAL_HIGH if score >= UNUSUAL_SCORE else UNUSUAL_LOW if score <= -UNUSUAL_SCORE else USUAL
    return Assessment(status=status, score=round(score, 2), reference=ref)

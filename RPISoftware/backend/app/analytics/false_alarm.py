"""Pure false-alarm reduction / anomaly classifier (ARCHITECTURE.md section B.3).

Distinguishes genuine hazards from benign events (cooking spikes, aerosol sprays,
sensor drift) using the shape of a single device's recent reading window, plus
multi-sensor corroboration supplied by the caller. Also flags slow micro-leak
trends that rise toward — but have not yet breached — the detection threshold.

SAFETY INVARIANT: this layer may only *downgrade the non-critical path*. A critical
reading or an edge-fired alarm is always GENUINE and is never suppressed — a real
alarm must never be silenced by a benign classification. Rule-based for cold-start;
the same feature vector feeds an ML classifier later (documented upgrade path).
"""

from __future__ import annotations

from dataclasses import dataclass

# classifications
GENUINE = "genuine"
TRANSIENT = "transient"  # spiked and returned (cooking / spray) — benign
DRIFT = "drift"  # slow baseline creep near threshold — sensor maintenance
LIKELY_BENIGN = "likely_benign"  # single flat slightly-over reading, uncorroborated
MICRO_LEAK_TREND = "micro_leak_trend"  # sub-threshold but rising — early warning
INSUFFICIENT_DATA = "insufficient_data"

# tuning (illustrative; belongs in per-sensor config later)
TRANSIENT_MAX_SECONDS = 90.0  # a spike that clears within this is likely cooking/spray
TREND_MIN_SECONDS = 240.0  # need this much history to call a slow trend
DRIFT_MIN_SECONDS = 1800.0


@dataclass(frozen=True)
class ReadingSample:
    ts: float  # epoch seconds (UTC)
    value: float


@dataclass(frozen=True)
class FalseAlarmAssessment:
    classification: str
    benign_score: float  # 0..1, how likely this is NOT a real hazard
    genuine_score: float  # 0..1
    reason: str
    suppress_escalation: bool  # hold in verification instead of escalating to alarm


def _slope(samples: list[ReadingSample]) -> float:
    """Least-squares slope (value per second). 0 when degenerate."""
    n = len(samples)
    if n < 2:
        return 0.0
    t0 = samples[0].ts
    xs = [s.ts - t0 for s in samples]
    ys = [s.value for s in samples]
    mx = sum(xs) / n
    my = sum(ys) / n
    denom = sum((x - mx) ** 2 for x in xs)
    if denom == 0:
        return 0.0
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / denom


def _up_crossings(samples: list[ReadingSample], detection: float) -> int:
    """Number of times the signal transitions from below to at/above detection."""
    crossings = 0
    prev_over = samples[0].value >= detection
    for s in samples[1:]:
        cur_over = s.value >= detection
        if cur_over and not prev_over:
            crossings += 1
        prev_over = cur_over
    return crossings


def classify(
    samples: list[ReadingSample],
    *,
    detection: float,
    critical: float,
    clear: float,
    multi_sensor: bool,
    edge_alarm: bool,
) -> FalseAlarmAssessment:
    """Classify a device's recent reading window.

    `multi_sensor` is TRUE only for *real* cross-sensor corroboration (a second device
    or neighbouring zone) — NOT repeated samples from one sensor. A lone sensor, however
    many times it repeats, can still be cooking/spray/drift; genuine corroboration is
    what unlocks an unconditional GENUINE on a sub-critical signal.
    """
    # --- safety: critical / edge alarm is always genuine, never suppressed ---
    peak = max((s.value for s in samples), default=0.0)
    if edge_alarm or peak >= critical:
        return FalseAlarmAssessment(GENUINE, 0.0, 1.0, "critical_or_edge_alarm", False)

    if len(samples) < 2:
        # Not enough history to judge — never suppress on ignorance.
        return FalseAlarmAssessment(INSUFFICIENT_DATA, 0.0, 0.0, "insufficient_history", False)

    samples = sorted(samples, key=lambda s: s.ts)
    span = samples[-1].ts - samples[0].ts
    latest = samples[-1].value
    slope = _slope(samples)
    over = [s for s in samples if s.value >= detection]

    # --- micro-leak trend: all sub-threshold but rising over a long window ---
    if peak < detection:
        rising_rate = detection * 0.0008  # ~ approaching threshold over the window
        if span >= TREND_MIN_SECONDS and slope >= rising_rate and latest > clear:
            return FalseAlarmAssessment(MICRO_LEAK_TREND, 0.2, 0.6, "sub_threshold_rising_trend", False)
        return FalseAlarmAssessment(INSUFFICIENT_DATA, 0.0, 0.0, "below_threshold_flat", False)

    duration_over = over[-1].ts - over[0].ts if over else 0.0
    crossings = _up_crossings(samples, detection)
    min_value = min(s.value for s in samples)
    spiked_and_returned = peak >= detection and latest < clear

    # --- single transient spike (cooking / spray): rose, already fell back, brief ---
    if spiked_and_returned and duration_over <= TRANSIENT_MAX_SECONDS and not multi_sensor:
        return FalseAlarmAssessment(TRANSIENT, 0.85, 0.15, "spike_then_decay_uncorroborated", True)

    # --- repeated/oscillatory spikes (recurrent cooking): crosses up repeatedly and
    #     dips back toward baseline between spikes, from a single sensor ---
    if crossings >= 2 and min_value < clear and not multi_sensor:
        return FalseAlarmAssessment(TRANSIENT, 0.8, 0.2, "oscillatory_spikes_uncorroborated", True)

    # --- sensor drift: long, slow flat creep near threshold, no real event ---
    if span >= DRIFT_MIN_SECONDS and abs(slope) < detection * 0.00005 and not multi_sensor and latest < detection * 1.2:
        return FalseAlarmAssessment(DRIFT, 0.7, 0.2, "slow_flat_creep", True)

    # --- genuine: sustained elevation AND (real corroboration OR clearly rising) ---
    if latest >= detection and (multi_sensor or slope > detection * 0.0005):
        return FalseAlarmAssessment(GENUINE, 0.1, 0.9, "sustained_elevated", False)

    # --- single, flat, slightly-over, uncorroborated: hold in verification (don't alarm yet) ---
    if latest >= detection and not multi_sensor:
        return FalseAlarmAssessment(LIKELY_BENIGN, 0.6, 0.4, "single_flat_uncorroborated", True)

    return FalseAlarmAssessment(INSUFFICIENT_DATA, 0.0, 0.0, "indeterminate", False)

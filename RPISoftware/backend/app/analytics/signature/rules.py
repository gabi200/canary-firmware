"""Rule-based hazard signature scorer (the decision side of the signature classifier).

Each label has core conditions, which must all hold or the label scores 0, and
supporting conditions: score = 0.5 + 0.5 x (supporting met / supporting total). A
condition on a missing (None) feature is not met. LABELS lists fire first, so a tie
resolves toward the dangerous reading.

SAFETY: the assessment can hold a corroborated, non-critical escalation (benign
label) or cancel a hold (fire label). It never raises an alarm, and callers check
critical readings and node alarms before it is consulted.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from app.analytics.signature.features import SignatureFeatures

LABELS = ("smouldering_fire", "flaming_fire", "gas_leak", "steam", "cooking", "aerosol")
NORMAL = "normal"
UNKNOWN = "unknown"
FIRE_LABELS = frozenset({"smouldering_fire", "flaming_fire"})
BENIGN_LABELS = frozenset({"steam", "cooking", "aerosol"})

FIRE_OVERRIDE_SCORE = 0.6  # a fire score at or above this cancels every hold
BENIGN_HOLD_CONFIDENCE = 0.7  # a benign label needs this confidence to hold
FIRE_MAX_FOR_HOLD = 0.4  # ...and every fire score must stay below this
NORMAL_CONFIDENCE = 0.8

MIN_SAMPLES = 4
MIN_SPAN_S = 60.0
_QUIET_RISE = 0.3
_QUIET_RH = 10.0
_QUIET_TEMP = 2.0
_FLAT_RISE = 0.1  # below this a channel reads "flat" in the summary


@dataclass(frozen=True)
class Condition:
    text: str
    test: Callable[[SignatureFeatures], bool]


def _get(f: SignatureFeatures, name: str) -> float | None:
    return getattr(f, name)


def at_least(name: str, limit: float) -> Condition:
    return Condition(f"{name} >= {limit:g}", lambda f: (v := _get(f, name)) is not None and v >= limit)


def at_most(name: str, limit: float) -> Condition:
    return Condition(f"{name} <= {limit:g}", lambda f: (v := _get(f, name)) is not None and v <= limit)


def below(name: str, limit: float, *, absent_ok: bool = False) -> Condition:
    text = f"{name} < {limit:g}" + (" (or absent)" if absent_ok else "")
    return Condition(text, lambda f: (v := _get(f, name)) is None and absent_ok or (v is not None and v < limit))


def within(name: str, low: float, high: float, *, high_inclusive: bool = False) -> Condition:
    op = "<=" if high_inclusive else "<"
    return Condition(
        f"{low:g} <= {name} {op} {high:g}",
        lambda f: (v := _get(f, name)) is not None and low <= v and (v <= high if high_inclusive else v < high),
    )


def any_of(*conditions: Condition) -> Condition:
    return Condition(" or ".join(c.text for c in conditions), lambda f: any(c.test(f) for c in conditions))


# label -> (core conditions, supporting conditions); spec section "rules.py"
SIGNATURES: dict[str, tuple[tuple[Condition, ...], tuple[Condition, ...]]] = {
    "smouldering_fire": (
        (at_least("rise_pm2_5", 0.5), at_least("rise_co", 0.3)),
        (below("decay_pm2_5", 0.4), below("decay_co", 0.4), below("temp_rate", 2), below("rh_delta", 8)),
    ),
    "flaming_fire": (
        (any_of(at_least("temp_rate", 2), at_least("temp_delta", 8)),
         any_of(at_least("rise_pm2_5", 0.5), at_least("rise_co", 0.3))),
        (below("decay_pm2_5", 0.4), at_least("temp_delta", 4), at_least("rise_co", 0.3)),
    ),
    "gas_leak": (
        (at_least("rise_gas", 0.5), below("rise_pm2_5", 0.3, absent_ok=True)),
        (below("decay_gas", 0.3), below("rise_co", 0.3), below("temp_delta", 2)),
    ),
    "steam": (
        (at_least("rh_delta", 12), at_least("rise_pm2_5", 0.3), below("rise_co", 0.2)),
        (below("temp_delta", 4), at_least("coarse_share", 1.5), at_least("presence_frac", 0.3)),
    ),
    "cooking": (
        (at_least("rise_pm2_5", 0.3), below("rise_co", 0.6), at_least("presence_frac", 0.3)),
        (within("temp_delta", 0.5, 6, high_inclusive=True), within("rh_delta", 3, 12),
         at_least("fine_share", 0.6), at_least("decay_pm2_5", 0.3)),
    ),
    "aerosol": (
        (at_least("rise_pm2_5", 0.5), at_most("onset_s_pm2_5", 60), below("rise_co", 0.2)),
        (at_least("decay_pm2_5", 0.5), below("rh_delta", 8), below("temp_delta", 1)),
    ),
}


@dataclass(frozen=True)
class SignatureAssessment:
    label: str
    confidence: float  # 0..1
    scores: dict[str, float]  # every label in LABELS
    evidence: list[str]

    @property
    def fire_score(self) -> float:
        return max(self.scores.get(label, 0.0) for label in FIRE_LABELS)

    @property
    def overrides_hold(self) -> bool:
        return self.fire_score >= FIRE_OVERRIDE_SCORE

    @property
    def allows_hold(self) -> bool:
        return (
            self.label in BENIGN_LABELS
            and self.confidence >= BENIGN_HOLD_CONFIDENCE
            and self.fire_score < FIRE_MAX_FOR_HOLD
        )


def _rise_text(name: str, rise: float | None) -> str | None:
    if rise is None:
        return None
    return f"{name} flat" if rise < _FLAT_RISE else f"{name} +{rise * 100:.0f}% of warn"


def _summary(f: SignatureFeatures, label: str) -> str:
    parts = [_rise_text("PM2.5", f.rise_pm2_5), _rise_text("CO", f.rise_co), _rise_text("gas", f.rise_gas)]
    if f.rh_delta is not None:
        parts.append(f"humidity +{f.rh_delta:.0f} pts")
    if f.temp_delta is not None:
        parts.append(f"temperature +{f.temp_delta:.1f} °C")
    if f.presence_frac is not None:
        parts.append("occupied" if f.presence_frac >= 0.3 else "unoccupied")
    return ", ".join(p for p in parts if p) + f" → {label.replace('_', ' ')}"


def _quiet(f: SignatureFeatures) -> bool:
    rises = [_get(f, f"rise_{c}") for c in ("co", "gas", "pm2_5", "pm1_0", "pm10")]
    return (
        all(r is None or r < _QUIET_RISE for r in rises)
        and (f.rh_delta is None or f.rh_delta < _QUIET_RH)
        and (f.temp_delta is None or f.temp_delta < _QUIET_TEMP)
    )


def assess(f: SignatureFeatures) -> SignatureAssessment:
    zero = dict.fromkeys(LABELS, 0.0)
    if (
        f.n_samples < MIN_SAMPLES
        or f.span_s < MIN_SPAN_S
        or all(_get(f, n) is None for n in ("rise_pm2_5", "rise_co", "rise_gas"))
    ):
        return SignatureAssessment(UNKNOWN, 0.0, zero, ["insufficient data"])

    scores = dict(zero)
    met: dict[str, list[Condition]] = {}
    for label, (core, support) in SIGNATURES.items():
        if all(c.test(f) for c in core):
            ok = [c for c in support if c.test(f)]
            scores[label] = 0.5 + 0.5 * len(ok) / len(support)
            met[label] = [*core, *ok]

    best = max(LABELS, key=lambda label: scores[label])  # first of equals: fire before benign
    if scores[best] > 0:
        evidence = [c.text for c in met[best]] + [_summary(f, best)]
        return SignatureAssessment(best, scores[best], scores, evidence)
    if _quiet(f):
        return SignatureAssessment(NORMAL, NORMAL_CONFIDENCE, scores, [_summary(f, NORMAL)])
    return SignatureAssessment(UNKNOWN, 0.0, scores, [_summary(f, UNKNOWN)])

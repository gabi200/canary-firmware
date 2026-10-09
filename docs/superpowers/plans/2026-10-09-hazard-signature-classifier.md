# Hazard Signature Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Label each air node's recent window (smouldering fire, flaming fire, gas leak, steam, cooking, aerosol, normal, unknown) from all of its channels together. Let that label hold benign escalations and cancel holds for fire, and run a synthetic-trained random forest beside it in shadow mode.

**Architecture:** Pure modules in `app/analytics/signature/` turn `node_status` payloads into a feature vector (`features.py`), score it with explicit rules (`rules.py`), and evaluate a JSON-exported random forest in pure Python (`model.py`). `AnalyticsService.classify_signature` loads the window and stores one `signature_assessments` row per evaluation. `IncidentService` applies the hold and override rules. The API adds a `signature` object to incidents, and the web dashboard shows a badge. Training lives in dev-only `backend/tools/signature/`.

**Tech Stack:** Python 3.12+, FastAPI, SQLAlchemy 2 async (SQLite in tests), pytest + pytest-asyncio, React + TypeScript (Vite). For training only: numpy and scikit-learn.

**Spec:** `docs/superpowers/specs/2026-10-09-hazard-signature-classifier-design.md`

## Global Constraints

- All paths below are relative to `RPISoftware/` unless they start with `docs/superpowers/`. Run `git` commands from `RPISoftware/`. Run backend commands from `RPISoftware/backend` with `.venv/bin/python -m pytest …` (the venv exists; create it with `python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"` if missing).
- Python ≥ 3.12 (the Docker image is `python:3.12-slim`); no syntax newer than 3.12.
- No new runtime dependencies. numpy and scikit-learn go only in a new `train` optional extra; nothing under `app/` imports them.
- `app/analytics/signature/` modules are pure: no DB access and no I/O, except `model.py` reading its JSON file.
- No new columns on existing tables (the schema is `create_all` only). New data goes in the new `signature_assessments` table.
- The signature window is 600 s. Rule constants: `FIRE_OVERRIDE_SCORE = 0.6`, `BENIGN_HOLD_CONFIDENCE = 0.7`, `FIRE_MAX_FOR_HOLD = 0.4`, `NORMAL_CONFIDENCE = 0.8`.
- Safety: a critical reading or a node-raised alarm is never held. The shadow prediction is never read by decision code. Any exception in signature classification is logged and the incident flow continues as if no signature existed.
- Benign labels: `steam`, `cooking`, `aerosol`. Fire labels: `smouldering_fire`, `flaming_fire`. The benign hold reason is `held_signature_<label>`.
- Match the surrounding code: module docstrings that explain the why, sparse comments, `from __future__ import annotations`.
- Every commit message ends with a blank line and then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Junk `node_status` payloads** (`{}` rows written by retention tests, numbers sent as strings, a warn threshold of 0, presence `"yes"`): the channel is treated as absent and nothing raises. Pinned in Task 1 (`test_parse_snapshot_tolerates_junk`).
2. **Duplicate timestamps in a window** (retained re-delivery, the three live documents in a burst): no division by zero; `temp_rate` ignores zero-length spans. Pinned in Task 1 (`test_duplicate_timestamps_do_not_divide_by_zero`).
3. **The committed model drifting from `FEATURE_NAMES`** after someone edits the features: the shadow output becomes `None` and the app keeps working, and a test fails loudly so the model gets retrained. Pinned in Task 3 (mismatch → `ValueError`/`None`) and Task 4 (`test_committed_model_matches_features`).
4. **Non-air devices that also use `node:channel` ids** (the water node `water-sensor:leak`): no assessment is stored and behaviour is unchanged. Pinned in Task 5 (`test_water_node_gets_no_signature`).
5. **A shadow model that confidently says "fire" on a benign window**: the state is still decided by the rules alone. Pinned in Task 5 (`test_shadow_prediction_never_changes_the_outcome`).

---

### Task 1: Window features

**Files:**
- Create: `backend/app/analytics/signature/__init__.py`
- Create: `backend/app/analytics/signature/features.py`
- Test: `backend/tests/test_signature_features.py`

**Interfaces:**
- Consumes: `app.analytics.environment.finite_number(value: object) -> float | None` (existing).
- Produces:
  - `CHANNELS: tuple[str, ...] = ("co", "gas", "pm2_5", "pm1_0", "pm10")`
  - `AirSnapshot(ts: float, values: Mapping[str, float], warn: Mapping[str, float], temperature_c: float | None, humidity_percent: float | None, presence: bool | None)` (frozen dataclass)
  - `parse_snapshot(ts: float, doc: object) -> AirSnapshot`
  - `SignatureFeatures` (frozen dataclass, 23 fields in this order: `rise_co, decay_co, onset_s_co, rise_gas, decay_gas, onset_s_gas, rise_pm2_5, decay_pm2_5, onset_s_pm2_5, rise_pm1_0, decay_pm1_0, onset_s_pm1_0, rise_pm10, decay_pm10, onset_s_pm10, rh_delta, temp_delta, temp_rate, fine_share, coarse_share, presence_frac, n_samples, span_s`), all `float | None` except `n_samples: float` and `span_s: float`. Method `as_vector() -> list[float | None]`.
  - `FEATURE_NAMES: tuple[str, ...]` (the field names in order)
  - `extract_features(snapshots: Sequence[AirSnapshot]) -> SignatureFeatures`

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_signature_features.py`:

```python
"""Signature window features: parsing node_status documents and the feature maths."""

from __future__ import annotations

import pytest

from app.analytics.signature.features import (
    FEATURE_NAMES,
    SignatureFeatures,
    extract_features,
    parse_snapshot,
)
from tests.hardware_docs import air_doc


def snap(t: float, **sections):
    return parse_snapshot(t, air_doc(**sections))


def test_parse_snapshot_reads_usable_channels():
    s = parse_snapshot(12.0, air_doc())
    assert s.ts == 12.0
    assert s.values == {"co": 3, "gas": 640, "pm2_5": 7, "pm1_0": 4, "pm10": 9}
    assert s.warn == {"co": 50, "gas": 1500, "pm2_5": 35, "pm1_0": 35, "pm10": 100}
    assert (s.temperature_c, s.humidity_percent, s.presence) == (22.4, 41.5, True)


def test_parse_snapshot_drops_invalid_warmup_and_fault_channels():
    s = parse_snapshot(0.0, air_doc(
        co={"state": "warmup"}, gas={"state": "fault"}, particulate={"valid": False},
        climate={"valid": False}, presence={"valid": False},
    ))
    assert s.values == {} and s.warn == {}
    assert (s.temperature_c, s.humidity_percent, s.presence) == (None, None, None)


def test_parse_snapshot_tolerates_junk():
    empty = parse_snapshot(0.0, {})
    assert empty.values == {} and empty.presence is None
    assert parse_snapshot(0.0, "not a document").values == {}
    s = parse_snapshot(0.0, air_doc(
        co={"ppm": "3"}, gas={"warn_adc": 0}, climate={"temperature_c": True}, presence={"detected": "yes"},
    ))
    assert "co" not in s.values and "gas" not in s.values
    assert s.temperature_c is None and s.humidity_percent == 41.5
    assert s.presence is None


def test_feature_names_and_vector_order():
    assert FEATURE_NAMES[:3] == ("rise_co", "decay_co", "onset_s_co")
    assert FEATURE_NAMES[-2:] == ("n_samples", "span_s")
    assert len(FEATURE_NAMES) == 23
    f = extract_features([])
    assert len(f.as_vector()) == 23
    assert (f.n_samples, f.span_s) == (0.0, 0.0)
    assert f.rise_pm2_5 is None and f.presence_frac is None


def test_channel_rise_decay_and_onset():
    pm = [7, 7, 7, 7, 7, 7, 10, 30, 60, 50, 40, 30]
    f = extract_features([snap(i * 15.0, particulate={"pm2_5": v}) for i, v in enumerate(pm)])
    # baseline = median of the earliest third (4 samples) = 7; peak 60 at t=120
    assert f.rise_pm2_5 == pytest.approx(53 / 35)
    assert f.decay_pm2_5 == pytest.approx(30 / 53)
    # last sample <= 7 + 0.1 * 35 before the peak is t=90 (value 10)
    assert f.onset_s_pm2_5 == pytest.approx(30.0)
    assert f.rise_co == 0.0 and f.decay_co == 0.0
    assert (f.n_samples, f.span_s) == (12.0, 165.0)


def test_climate_deltas_and_temperature_rate():
    temps = [22, 22, 22, 22, 23, 25, 26, 26]
    f = extract_features([snap(i * 15.0, climate={"temperature_c": v, "humidity_percent": 40})
                          for i, v in enumerate(temps)])
    assert f.temp_delta == pytest.approx(4.0)
    assert f.temp_rate == pytest.approx(4.0)  # 22 -> 26 within 60 s
    assert f.rh_delta == pytest.approx(0.0)


def test_presence_fraction():
    flags = [True, False, True, True]
    f = extract_features([snap(i * 15.0, presence={"detected": v}) for i, v in enumerate(flags)])
    assert f.presence_frac == pytest.approx(0.75)


def test_pm_size_shares_use_raw_increases():
    rows = [(7, 4, 9)] * 4 + [(57, 34, 109)] * 2
    f = extract_features([snap(i * 15.0, particulate={"pm2_5": a, "pm1_0": b, "pm10": c})
                          for i, (a, b, c) in enumerate(rows)])
    assert f.fine_share == pytest.approx(30 / 50)
    assert f.coarse_share == pytest.approx(100 / 50)


def test_pm_size_shares_are_none_when_pm_is_flat():
    f = extract_features([snap(i * 15.0) for i in range(6)])
    assert f.fine_share is None and f.coarse_share is None


def test_missing_or_short_channels_are_none():
    f = extract_features([snap(i * 15.0, co={"valid": False}) for i in range(6)])
    assert f.rise_co is None and f.decay_co is None and f.onset_s_co is None
    short = extract_features([snap(0.0), snap(15.0)])
    assert short.rise_pm2_5 is None and short.temp_delta is None


def test_duplicate_timestamps_do_not_divide_by_zero():
    snaps = [snap(0.0), snap(0.0), snap(0.0, climate={"temperature_c": 30}), snap(0.0)]
    f = extract_features(snaps)
    assert f.span_s == 0.0
    assert f.temp_rate == 0.0


def test_snapshots_are_sorted_by_time():
    pm = [(30.0, 60), (0.0, 7), (15.0, 7), (45.0, 7)]
    f = extract_features([snap(t, particulate={"pm2_5": v}) for t, v in pm])
    assert f.decay_pm2_5 == pytest.approx(1.0)  # peak at t=30, back to 7 by t=45
    assert isinstance(f, SignatureFeatures)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_signature_features.py -v`
Expected: collection error, `ModuleNotFoundError: No module named 'app.analytics.signature'`.

- [ ] **Step 3: Write the implementation**

Create `backend/app/analytics/signature/__init__.py`:

```python
"""Hazard signature classifier (docs/superpowers/specs/2026-10-09-hazard-signature-classifier-design.md)."""
```

Create `backend/app/analytics/signature/features.py`:

```python
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_signature_features.py -v`
Expected: 12 passed.

- [ ] **Step 5: Commit**

```bash
git add backend/app/analytics/signature/__init__.py backend/app/analytics/signature/features.py backend/tests/test_signature_features.py
git commit -m "Add signature window features for air nodes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Rule scorer and scenario windows

**Files:**
- Create: `backend/app/analytics/signature/rules.py`
- Create: `backend/tests/signature_windows.py` (shared scenario builders; Task 5 adds DB helpers)
- Test: `backend/tests/test_signature_rules.py`

**Interfaces:**
- Consumes: `SignatureFeatures`, `extract_features`, `parse_snapshot`, `AirSnapshot` (Task 1).
- Produces:
  - `LABELS = ("smouldering_fire", "flaming_fire", "gas_leak", "steam", "cooking", "aerosol")`, `NORMAL = "normal"`, `UNKNOWN = "unknown"`, `FIRE_LABELS`, `BENIGN_LABELS`, and the four constants from Global Constraints.
  - `SignatureAssessment(label: str, confidence: float, scores: dict[str, float], evidence: list[str])` (frozen dataclass) with properties `fire_score: float`, `overrides_hold: bool` and `allows_hold: bool`.
  - `assess(features: SignatureFeatures) -> SignatureAssessment`
  - In `tests/signature_windows.py`: `STEP_S = 15.0`, `SAMPLES = 40`, `SCENARIOS: dict[str, dict]` (keys `normal, steam, cooking, aerosol, gas_leak, smouldering_fire, flaming_fire, humidity_only`), `scenario_docs(name: str, start_uptime_ms: int = 1_000_000) -> list[tuple[float, dict]]`, `scenario_snapshots(name: str) -> list[AirSnapshot]`.

- [ ] **Step 1: Write the scenario builders**

Create `backend/tests/signature_windows.py`:

```python
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
```

- [ ] **Step 2: Write the failing rule tests**

Create `backend/tests/test_signature_rules.py`:

```python
"""Signature rules: one window per label, the fallbacks, and the hold properties."""

from __future__ import annotations

import pytest

from app.analytics.signature.features import extract_features, parse_snapshot
from app.analytics.signature.rules import LABELS, SignatureAssessment, assess
from tests.hardware_docs import air_doc
from tests.signature_windows import scenario_snapshots


def _assess(name: str) -> SignatureAssessment:
    return assess(extract_features(scenario_snapshots(name)))


@pytest.mark.parametrize(("scenario", "label", "confidence"), [
    ("steam", "steam", 1.0),
    ("cooking", "cooking", 1.0),
    ("aerosol", "aerosol", 1.0),
    ("gas_leak", "gas_leak", 1.0),
    ("smouldering_fire", "smouldering_fire", 1.0),
    ("flaming_fire", "flaming_fire", 1.0),
    ("normal", "normal", 0.8),
    ("humidity_only", "unknown", 0.0),
])
def test_scenarios_get_their_label(scenario, label, confidence):
    a = _assess(scenario)
    assert (a.label, a.confidence) == (label, pytest.approx(confidence))
    assert set(a.scores) == set(LABELS)


def test_steam_also_partly_matches_cooking_but_steam_wins():
    a = _assess("steam")
    assert a.scores["cooking"] == pytest.approx(0.625)
    assert a.scores["steam"] == pytest.approx(1.0)


def test_short_window_is_unknown():
    a = assess(extract_features(scenario_snapshots("steam")[:3]))
    assert (a.label, a.confidence, a.evidence) == ("unknown", 0.0, ["insufficient data"])


def test_window_without_hazard_channels_is_unknown():
    doc = air_doc(co={"valid": False}, gas={"state": "fault"}, particulate={"valid": False})
    a = assess(extract_features([parse_snapshot(i * 15.0, doc) for i in range(10)]))
    assert a.label == "unknown" and a.evidence == ["insufficient data"]


def test_evidence_lists_met_conditions_and_a_summary():
    a = _assess("steam")
    assert "rh_delta >= 12" in a.evidence
    assert "coarse_share >= 1.5" in a.evidence
    assert a.evidence[-1] == (
        "PM2.5 +151% of warn, CO flat, gas flat, humidity +28 pts, temperature +1.6 °C, occupied → steam"
    )


@pytest.mark.parametrize(("scenario", "overrides", "allows"), [
    ("steam", False, True),
    ("cooking", False, True),
    ("aerosol", False, True),
    ("smouldering_fire", True, False),
    ("flaming_fire", True, False),
    ("gas_leak", False, False),
    ("normal", False, False),
    ("humidity_only", False, False),
])
def test_hold_properties(scenario, overrides, allows):
    a = _assess(scenario)
    assert (a.overrides_hold, a.allows_hold) == (overrides, allows)


def test_a_middling_fire_score_blocks_a_benign_hold_without_overriding():
    scores = dict.fromkeys(LABELS, 0.0) | {"steam": 0.9, "smouldering_fire": 0.5}
    a = SignatureAssessment("steam", 0.9, scores, [])
    assert a.fire_score == 0.5
    assert not a.allows_hold and not a.overrides_hold


def test_low_confidence_benign_label_does_not_hold():
    scores = dict.fromkeys(LABELS, 0.0) | {"cooking": 0.625}
    assert not SignatureAssessment("cooking", 0.625, scores, []).allows_hold
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_signature_rules.py -v`
Expected: collection error, `ModuleNotFoundError: No module named 'app.analytics.signature.rules'`.

- [ ] **Step 4: Write the implementation**

Create `backend/app/analytics/signature/rules.py`:

```python
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_signature_rules.py tests/test_signature_features.py -v`
Expected: all pass. If a scenario test fails, print `extract_features(scenario_snapshots(name))` and compare it with the rule table in the spec. Fix the scenario curve in `signature_windows.py` or a bug in the code, but never change a rule threshold: the thresholds come from the spec.

- [ ] **Step 6: Commit**

```bash
git add backend/app/analytics/signature/rules.py backend/tests/signature_windows.py backend/tests/test_signature_rules.py
git commit -m "Add rule-based hazard signature scorer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Shadow forest evaluator

**Files:**
- Create: `backend/app/analytics/signature/model.py`
- Test: `backend/tests/test_signature_model.py`

**Interfaces:**
- Consumes: `FEATURE_NAMES`, `SignatureFeatures` (Task 1).
- Produces:
  - `MODEL_PATH: Path` (`app/analytics/signature/signature_model_v1.json`)
  - `ShadowPrediction(label: str, confidence: float, model_version: str)` (frozen dataclass)
  - `Forest(version: str, classes: tuple[str, ...], trees: tuple[dict, ...])`
  - `forest_from_dict(data: object) -> Forest` (raises `ValueError`)
  - `load_forest(path: Path) -> Forest` (raises `OSError` or `ValueError`)
  - `probabilities(forest: Forest, features: SignatureFeatures) -> list[float]`
  - `predict(features: SignatureFeatures, path: Path = MODEL_PATH) -> ShadowPrediction | None` (never raises; caches per path)
  - JSON tree layout: `feature`, `threshold`, `left`, `right` (`-1` = leaf), `value` (class probabilities on leaves, `[]` on split nodes), `missing_left` (bool per node).

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_signature_model.py`:

```python
"""Shadow forest evaluator: traversal, missing values, averaging, and failure handling."""

from __future__ import annotations

import json

import pytest

from app.analytics.signature.features import FEATURE_NAMES, SignatureFeatures
from app.analytics.signature.model import forest_from_dict, predict, probabilities

PM = FEATURE_NAMES.index("rise_pm2_5")
RH = FEATURE_NAMES.index("rh_delta")


def features(**values) -> SignatureFeatures:
    base = dict.fromkeys(FEATURE_NAMES)
    base.update(n_samples=40.0, span_s=585.0)
    base.update(values)
    return SignatureFeatures(**base)


def tiny_model() -> dict:
    def split(feature: int, threshold: float, left_leaf: list[float], right_leaf: list[float]) -> dict:
        return {"feature": [feature, -2, -2], "threshold": [threshold, -2.0, -2.0], "left": [1, -1, -1],
                "right": [2, -1, -1], "value": [[], left_leaf, right_leaf], "missing_left": [True, False, False]}
    return {"version": "test", "feature_names": list(FEATURE_NAMES), "classes": ["normal", "steam"],
            "trees": [split(PM, 0.5, [1.0, 0.0], [0.0, 1.0]), split(RH, 10.0, [1.0, 0.0], [0.2, 0.8])]}


def test_probabilities_average_the_trees():
    forest = forest_from_dict(tiny_model())
    assert probabilities(forest, features(rise_pm2_5=1.0, rh_delta=20.0)) == pytest.approx([0.1, 0.9])


def test_threshold_is_inclusive_on_the_left():
    forest = forest_from_dict(tiny_model())
    assert probabilities(forest, features(rise_pm2_5=0.5, rh_delta=10.0)) == pytest.approx([1.0, 0.0])


def test_missing_values_follow_missing_left():
    forest = forest_from_dict(tiny_model())
    assert probabilities(forest, features()) == pytest.approx([1.0, 0.0])


def test_predict_returns_the_best_class(tmp_path):
    path = tmp_path / "model.json"
    path.write_text(json.dumps(tiny_model()))
    p = predict(features(rise_pm2_5=1.0, rh_delta=20.0), path)
    assert (p.label, p.confidence, p.model_version) == ("steam", pytest.approx(0.9), "test")


@pytest.mark.parametrize("mutate", [
    lambda m: m.update(feature_names=list(FEATURE_NAMES)[:-1]),
    lambda m: m.update(classes=[]),
    lambda m: m["trees"][0].update(left=[1, -1]),
    lambda m: m["trees"][0]["value"].__setitem__(1, [1.0]),
    lambda m: m.pop("trees"),
])
def test_malformed_models_are_rejected(mutate):
    model = tiny_model()
    mutate(model)
    with pytest.raises(ValueError):
        forest_from_dict(model)


def test_predict_is_none_for_missing_or_broken_files(tmp_path):
    assert predict(features(), tmp_path / "absent.json") is None
    broken = tmp_path / "broken.json"
    broken.write_text("{not json")
    assert predict(features(), broken) is None
    stale = tmp_path / "stale.json"
    model = tiny_model()
    model["feature_names"] = ["old_feature"]
    stale.write_text(json.dumps(model))
    assert predict(features(), stale) is None


def test_predict_is_none_when_a_tree_points_outside_its_arrays(tmp_path):
    model = tiny_model()
    model["trees"][0]["left"] = [7, -1, -1]
    path = tmp_path / "bad_index.json"
    path.write_text(json.dumps(model))
    assert predict(features(rise_pm2_5=0.1), path) is None
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_signature_model.py -v`
Expected: collection error, `ModuleNotFoundError: No module named 'app.analytics.signature.model'`.

- [ ] **Step 3: Write the implementation**

Create `backend/app/analytics/signature/model.py`:

```python
"""Shadow random-forest evaluator for the hazard signature classifier.

Walks a forest exported by tools/signature/train.py as JSON, in pure Python, so the
Pi needs no numpy or scikit-learn. Shadow mode only: callers store and log the
prediction, and no decision reads it. A missing, invalid or out-of-date model file
disables the shadow output and never raises.
"""

from __future__ import annotations

import json
import logging
import struct
from dataclasses import dataclass
from pathlib import Path

from app.analytics.signature.features import FEATURE_NAMES, SignatureFeatures

log = logging.getLogger("canary.signature")

MODEL_PATH = Path(__file__).with_name("signature_model_v1.json")
_TREE_KEYS = ("feature", "threshold", "left", "right", "value", "missing_left")


@dataclass(frozen=True)
class ShadowPrediction:
    label: str
    confidence: float
    model_version: str


@dataclass(frozen=True)
class Forest:
    version: str
    classes: tuple[str, ...]
    trees: tuple[dict, ...]


def forest_from_dict(data: object) -> Forest:
    try:
        if list(data["feature_names"]) != list(FEATURE_NAMES):
            raise ValueError("feature_names do not match FEATURE_NAMES; retrain the model")
        version = str(data["version"])
        classes = tuple(str(c) for c in data["classes"])
        trees = tuple(data["trees"])
        for tree in trees:
            n = len(tree["left"])
            if n == 0 or any(len(tree[key]) != n for key in _TREE_KEYS):
                raise ValueError("tree arrays differ in length")
            for left, row in zip(tree["left"], tree["value"]):
                if left == -1 and len(row) != len(classes):
                    raise ValueError("leaf value width does not match classes")
    except (KeyError, TypeError) as exc:
        raise ValueError(f"malformed model: {exc!r}") from exc
    if not classes or not trees:
        raise ValueError("model has no classes or no trees")
    return Forest(version, classes, trees)


def load_forest(path: Path) -> Forest:
    with open(path, encoding="utf-8") as fh:
        return forest_from_dict(json.load(fh))


def _f32(x: float) -> float:
    """scikit-learn compares features as float32; match it so exported splits agree exactly."""
    try:
        return struct.unpack("f", struct.pack("f", x))[0]
    except OverflowError:
        return x


def probabilities(forest: Forest, features: SignatureFeatures) -> list[float]:
    x = features.as_vector()
    totals = [0.0] * len(forest.classes)
    for tree in forest.trees:
        left, right = tree["left"], tree["right"]
        node = 0
        for _ in range(len(left)):  # bounded: a malformed tree cannot loop forever
            if left[node] == -1:
                break
            value = x[tree["feature"][node]]
            go_left = tree["missing_left"][node] if value is None else _f32(value) <= tree["threshold"][node]
            node = left[node] if go_left else right[node]
        else:
            raise ValueError("tree deeper than its node count")
        for k, p in enumerate(tree["value"][node]):
            totals[k] += p
    return [t / len(forest.trees) for t in totals]


_cache: dict[Path, Forest | None] = {}


def predict(features: SignatureFeatures, path: Path = MODEL_PATH) -> ShadowPrediction | None:
    if path not in _cache:
        try:
            _cache[path] = load_forest(path)
        except (OSError, ValueError) as exc:
            log.warning("signature shadow model %s unavailable: %s", path, exc)
            _cache[path] = None
    forest = _cache[path]
    if forest is None:
        return None
    try:
        probs = probabilities(forest, features)
    except (IndexError, TypeError, ValueError) as exc:
        log.warning("signature shadow model %s failed: %s", path, exc)
        return None
    best = max(range(len(probs)), key=probs.__getitem__)
    return ShadowPrediction(forest.classes[best], probs[best], forest.version)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_signature_model.py -v`
Expected: 11 passed.

- [ ] **Step 5: Commit**

```bash
git add backend/app/analytics/signature/model.py backend/tests/test_signature_model.py
git commit -m "Add pure-Python shadow forest evaluator for signatures

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Synthetic data, training, and the committed model

**Files:**
- Create: `backend/tools/__init__.py` (empty)
- Create: `backend/tools/signature/__init__.py` (empty)
- Create: `backend/tools/signature/synth.py`
- Create: `backend/tools/signature/train.py`
- Create (generated): `backend/app/analytics/signature/signature_model_v1.json`
- Modify: `backend/pyproject.toml` (add the `train` extra)
- Test: `backend/tests/test_signature_training.py`

**Interfaces:**
- Consumes: `parse_snapshot`, `AirSnapshot`, `extract_features`, `FEATURE_NAMES`, `SignatureFeatures` (Task 1); `assess` (Task 2); `MODEL_PATH`, `forest_from_dict`, `load_forest`, `probabilities`, `predict` (Task 3).
- Produces:
  - `tools.signature.synth`: `CLASSES = ("normal", "steam", "cooking", "aerosol", "gas_leak", "smouldering_fire", "flaming_fire", "unknown")` and `generate(seed: int, n_per_class: int) -> list[tuple[str, list[AirSnapshot]]]`.
  - `tools.signature.train`: `MISSING = -1.0`, `to_matrix(rows: list[SignatureFeatures]) -> np.ndarray`, `train_forest(features, labels, *, n_estimators=40, max_depth=6, seed=0) -> RandomForestClassifier`, `export(clf, version="v1") -> dict`, `main(argv: list[str] | None = None) -> None`.

- [ ] **Step 1: Add the `train` extra**

In `backend/pyproject.toml`, under `[project.optional-dependencies]`, after the `dev = [...]` list, add:

```toml
# Offline training of the shadow signature model (tools/signature); never installed on the Pi.
train = [
    "numpy>=1.26",
    "scikit-learn>=1.4",
]
```

Then install it: `.venv/bin/pip install -q -e ".[dev,train]"`.

- [ ] **Step 2: Write the failing tests**

Create `backend/tests/test_signature_training.py`:

```python
"""Synthetic training data, the sklearn export round trip, and the committed model."""

from __future__ import annotations

import pytest

from app.analytics.signature.features import FEATURE_NAMES, extract_features
from app.analytics.signature.model import MODEL_PATH, forest_from_dict, load_forest, predict, probabilities
from app.analytics.signature.rules import assess
from tests.signature_windows import scenario_snapshots
from tools.signature.synth import CLASSES, generate


def test_generate_is_deterministic_and_shaped():
    a, b = generate(seed=1, n_per_class=5), generate(seed=1, n_per_class=5)
    assert len(a) == len(CLASSES) * 5
    assert [label for label, _ in a] == [label for label, _ in b]
    assert all(len(snaps) == 40 for _, snaps in a)
    assert a[7][1][20] == b[7][1][20]


def test_rules_mostly_agree_with_synthetic_labels():
    windows = generate(seed=2, n_per_class=25)
    agree = sum(assess(extract_features(snaps)).label == label for label, snaps in windows)
    assert agree / len(windows) >= 0.7


def test_export_round_trips_sklearn_probabilities():
    pytest.importorskip("sklearn")
    from tools.signature.train import export, to_matrix, train_forest

    windows = generate(seed=3, n_per_class=30)
    feats = [extract_features(snaps) for _, snaps in windows]
    clf = train_forest(feats, [label for label, _ in windows], n_estimators=5, max_depth=5, seed=0)
    forest = forest_from_dict(export(clf, version="parity"))
    expected = clf.predict_proba(to_matrix(feats))
    for f, row in zip(feats, expected):
        assert probabilities(forest, f) == pytest.approx(list(row), abs=1e-5)


def test_committed_model_matches_features():
    forest = load_forest(MODEL_PATH)
    assert forest.version == "v1"
    assert set(forest.classes) == set(CLASSES)
    prediction = predict(extract_features(scenario_snapshots("steam")))
    assert prediction is not None and prediction.label in CLASSES
    assert len(FEATURE_NAMES) == 23
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_signature_training.py -v`
Expected: collection error, `ModuleNotFoundError: No module named 'tools'`.

- [ ] **Step 4: Write the synthetic generator**

Create the empty files `backend/tools/__init__.py` and `backend/tools/signature/__init__.py`.

Create `backend/tools/signature/synth.py`:

```python
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
```

- [ ] **Step 5: Write the trainer**

Create `backend/tools/signature/train.py`:

```python
"""Train the shadow signature model on synthetic windows and export it as JSON.

Run from RPISoftware/backend with the train extra installed:
    pip install -e ".[train]"
    python -m tools.signature.train
It overwrites app/analytics/signature/signature_model_v1.json; commit the result.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score, confusion_matrix
from sklearn.model_selection import train_test_split

from app.analytics.signature.features import FEATURE_NAMES, SignatureFeatures, extract_features
from app.analytics.signature.model import MODEL_PATH
from app.analytics.signature.rules import assess
from tools.signature.synth import CLASSES, generate

MODEL_VERSION = "v1"
# Every feature is >= 0, so -1 marks "missing"; export() routes missing values the same way.
MISSING = -1.0
VALUE_DECIMALS = 6


def to_matrix(rows: list[SignatureFeatures]) -> np.ndarray:
    return np.array([[MISSING if v is None else v for v in f.as_vector()] for f in rows], dtype=np.float64)


def train_forest(features: list[SignatureFeatures], labels: list[str], *, n_estimators: int = 40,
                 max_depth: int = 6, seed: int = 0) -> RandomForestClassifier:
    clf = RandomForestClassifier(n_estimators=n_estimators, max_depth=max_depth, random_state=seed)
    clf.fit(to_matrix(features), np.array(labels))
    return clf


def export(clf: RandomForestClassifier, version: str = MODEL_VERSION) -> dict:
    trees = []
    for estimator in clf.estimators_:
        t = estimator.tree_
        values = []
        for left, row in zip(t.children_left, t.value[:, 0, :]):
            total = float(row.sum())
            leaf = [round(float(v) / total, VALUE_DECIMALS) if total else 0.0 for v in row]
            values.append(leaf if left == -1 else [])
        trees.append({
            "feature": [int(i) for i in t.feature],
            "threshold": [float(x) for x in t.threshold],
            "left": [int(i) for i in t.children_left],
            "right": [int(i) for i in t.children_right],
            "value": values,
            "missing_left": [bool(MISSING <= x) for x in t.threshold],
        })
    return {"version": version, "feature_names": list(FEATURE_NAMES), "classes": [str(c) for c in clf.classes_],
            "trees": trees}


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Train the shadow signature model on synthetic windows.")
    parser.add_argument("--per-class", type=int, default=400)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--out", type=Path, default=MODEL_PATH)
    args = parser.parse_args(argv)

    windows = generate(seed=args.seed, n_per_class=args.per_class)
    labels = [label for label, _ in windows]
    features = [extract_features(snaps) for _, snaps in windows]
    f_train, f_test, y_train, y_test = train_test_split(
        features, labels, test_size=0.25, random_state=args.seed, stratify=labels)
    clf = train_forest(f_train, y_train, seed=args.seed)

    predicted = list(clf.predict(to_matrix(f_test)))
    rules = [assess(f).label for f in f_test]
    print(f"model vs synthetic truth: {accuracy_score(y_test, predicted):.3f}")
    print(f"rules vs synthetic truth: {accuracy_score(y_test, rules):.3f}")
    print(f"model vs rules:           {accuracy_score(rules, predicted):.3f}")
    print("confusion matrix (rows = truth, columns = model, same order):")
    for name, row in zip(CLASSES, confusion_matrix(y_test, predicted, labels=list(CLASSES))):
        print(f"{name:>17} " + " ".join(f"{n:4d}" for n in row))

    args.out.write_text(json.dumps(export(clf), separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Train and export the committed model**

Run: `.venv/bin/python -m tools.signature.train`
Expected: three accuracy lines, an 8×8 confusion matrix, and `wrote …/signature_model_v1.json`. Record the three accuracy numbers for the final report. Check the size with `ls -la app/analytics/signature/signature_model_v1.json`; it should be under 1 MB.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_signature_training.py tests/test_signature_model.py -v`
Expected: all pass. If `test_rules_mostly_agree_with_synthetic_labels` falls below 0.7, print the per-class agreement and narrow that class's parameter ranges in `synth.py` (for example the amplitude floor). Never change `rules.py`. Then re-run Step 6 so the model is trained on the corrected data.

- [ ] **Step 8: Commit**

```bash
git add backend/pyproject.toml backend/tools backend/app/analytics/signature/signature_model_v1.json backend/tests/test_signature_training.py
git commit -m "Train shadow signature model on synthetic windows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Storage, classification service, and the incident safety rules

**Files:**
- Modify: `backend/app/models.py` (add `SignatureAssessmentRow` after `NodeStatus`)
- Modify: `backend/app/retention.py` (prune the new table)
- Modify: `backend/app/analytics/service.py` (add `classify_signature`)
- Modify: `backend/app/incidents/service.py` (call it; apply hold and override)
- Modify: `backend/tests/signature_windows.py` (add `publish`, `seed_history`)
- Test: `backend/tests/test_signature_flow.py`

**Interfaces:**
- Consumes: `parse_snapshot`, `extract_features` (Task 1); `assess`, `SignatureAssessment` (Task 2); `app.analytics.signature.model.predict` (Task 3, called through the module so tests can monkeypatch it); `scenario_docs` (Task 2).
- Produces:
  - `SignatureAssessmentRow` (table `signature_assessments`): `id: int`, `incident_id: str`, `node_id: str`, `label: str`, `confidence: float`, `scores: dict`, `evidence: list`, `shadow_label: str | None`, `shadow_confidence: float | None`, `model_version: str | None`, `ts: datetime`.
  - `SIGNATURE_WINDOW_S = 600` in `app/analytics/service.py`.
  - `AnalyticsService.classify_signature(self, node_id: str, incident_id: str) -> SignatureAssessment | None`.
  - In `tests/signature_windows.py`: `async publish(base: str, doc: dict) -> None` and `async seed_history(name: str, *, live: int = 3, readings: bool = True) -> list[dict]`.

- [ ] **Step 1: Add the DB test helpers**

Append to `backend/tests/signature_windows.py`, and add these imports at the top with the others:

```python
import json
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete

from app.db import SessionLocal
from app.ingestion.hardware import handle_hardware_message
from app.models import NodeStatus, SensorReading
```

```python
async def publish(base: str, doc: dict) -> None:
    await handle_hardware_message(f"{base}/status", json.dumps(doc).encode())


async def seed_history(name: str, *, live: int = 3, readings: bool = True) -> list[dict]:
    """Register the `canary` air node, then store the scenario's documents except the
    last `live` as if they had arrived over the past ~10 minutes: node_status rows and,
    with `readings`, the PM2.5 sensor_readings the false-alarm layer looks at.
    Returns the `live` documents, still to be published."""
    docs = scenario_docs(name)
    await publish("canary", docs[0][1])
    now = datetime.now(timezone.utc)
    async with SessionLocal() as s:
        await s.execute(delete(NodeStatus).where(NodeStatus.node_id == "canary"))
        await s.execute(delete(SensorReading).where(SensorReading.device_id.like("canary:%")))
        for t, doc in docs[:-live]:
            ts = now - timedelta(seconds=590 - t)
            s.add(NodeStatus(node_id="canary", ts=ts, uptime_ms=doc["uptime_ms"], payload=doc))
            if readings:
                s.add(SensorReading(
                    device_id="canary:particulate", building_id="bld_007", floor_id="flr_03", unit_id="common",
                    zone_id="zone_hallway", sensor_type="particulate", value=doc["particulate"]["pm2_5"],
                    units="ug/m3", epoch=1, seq=doc["uptime_ms"], ts=ts))
        await s.commit()
    return [doc for _, doc in docs[-live:]]
```

- [ ] **Step 2: Write the failing flow tests**

Create `backend/tests/test_signature_flow.py`:

```python
"""Hazard signature classifier end to end through hardware ingest."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.analytics.service import AnalyticsService
from app.analytics.signature.model import ShadowPrediction
from app.db import SessionLocal
from app.ingestion import hardware
from app.models import SignatureAssessmentRow
from app.retention import prune_old_rows
from tests.conftest import auth_token
from tests.hardware_docs import air_doc, water_doc
from tests.signature_windows import publish, seed_history


@pytest.fixture(autouse=True)
def _fresh_hub_state():
    hardware.reset_state()
    yield
    hardware.reset_state()


@pytest.fixture
def no_classifier(monkeypatch):
    async def broken(self, node_id: str, incident_id: str):
        raise RuntimeError("classifier down")
    monkeypatch.setattr(AnalyticsService, "classify_signature", broken)


async def _active(client) -> list[dict]:
    headers = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    r = await client.get("/api/v1/buildings/bld_007/incidents", params={"active": True}, headers=headers)
    return r.json()


async def _assessments(incident_id: str) -> list[SignatureAssessmentRow]:
    async with SessionLocal() as s:
        q = (select(SignatureAssessmentRow).where(SignatureAssessmentRow.incident_id == incident_id)
             .order_by(SignatureAssessmentRow.id))
        return list((await s.scalars(q)).all())


async def _publish_all(docs: list[dict]) -> None:
    for doc in docs:
        await publish("canary", doc)


async def test_corroborated_steam_is_held_in_verification(client):
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    assert (inc["hazard_type"], inc["state"]) == ("particulate", "verification")
    assert inc["false_alarm_class"] == "genuine"  # the old layer alone would have alarmed
    rows = await _assessments(inc["id"])
    assert len(rows) == 3
    assert (rows[-1].node_id, rows[-1].label, rows[-1].confidence) == ("canary", "steam", pytest.approx(1.0))


async def test_steam_without_the_classifier_reaches_alarm(client, no_classifier):
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    assert inc["state"] == "alarm"
    assert await _assessments(inc["id"]) == []


async def test_fire_signature_cancels_a_false_alarm_hold(client):
    await _publish_all(await seed_history("smouldering_fire", readings=False))
    [inc] = await _active(client)
    assert inc["false_alarm_class"] == "likely_benign"
    assert inc["state"] == "alarm"


async def test_flat_smoke_is_held_without_the_classifier(client, no_classifier):
    await _publish_all(await seed_history("smouldering_fire", readings=False))
    [inc] = await _active(client)
    assert (inc["false_alarm_class"], inc["state"]) == ("likely_benign", "verification")


async def test_critical_reading_during_steam_is_not_held(client):
    live = await seed_history("steam")
    await _publish_all(live)
    await publish("canary", air_doc(uptime_ms=live[-1]["uptime_ms"] + 15000,
                                    particulate={"pm2_5": 200, "pm10": 260, "state": "danger"}))
    [inc] = await _active(client)
    assert inc["state"] == "alarm"


async def test_shadow_prediction_never_changes_the_outcome(client, monkeypatch):
    monkeypatch.setattr("app.analytics.signature.model.predict",
                        lambda features, path=None: ShadowPrediction("smouldering_fire", 0.99, "test"))
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    assert inc["state"] == "verification"
    row = (await _assessments(inc["id"]))[-1]
    assert (row.label, row.shadow_label, row.shadow_confidence, row.model_version) == (
        "steam", "smouldering_fire", 0.99, "test")


async def test_water_node_gets_no_signature(client):
    await publish("water-sensor", water_doc(uptime_ms=1000))
    await publish("water-sensor", water_doc(uptime_ms=2000, sensor={"state": "wet", "adc": 1500}, leak_latched=True))
    [inc] = await _active(client)
    assert (inc["hazard_type"], inc["state"]) == ("water_leak", "alarm")
    assert await _assessments(inc["id"]) == []


async def test_old_assessments_are_pruned(client):
    async with SessionLocal() as s:
        s.add(SignatureAssessmentRow(incident_id="inc_old", node_id="canary", label="steam", confidence=0.9,
                                     scores={}, evidence=[], ts=datetime.now(timezone.utc) - timedelta(days=30)))
        await s.commit()
    deleted = await prune_old_rows()
    assert deleted["signature_assessments"] == 1
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_signature_flow.py -v`
Expected: collection error, `ImportError: cannot import name 'SignatureAssessmentRow' from 'app.models'`.

- [ ] **Step 4: Add the table**

In `backend/app/models.py`, after the `NodeStatus` class, add:

```python
class SignatureAssessmentRow(Base):
    """Hazard signature classifier output, one row per incident evaluation of an air node
    (docs/superpowers/specs/2026-10-09-hazard-signature-classifier-design.md). The shadow_*
    fields are the model's opinion only; no decision reads them."""

    __tablename__ = "signature_assessments"
    __table_args__ = (Index("ix_signature_incident_id", "incident_id", "id"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    incident_id: Mapped[str] = mapped_column(String)  # indexed by ix_signature_incident_id
    node_id: Mapped[str] = mapped_column(String)
    label: Mapped[str] = mapped_column(String)
    confidence: Mapped[float] = mapped_column(Float)
    scores: Mapped[dict] = mapped_column(JSON, default=dict)
    evidence: Mapped[list] = mapped_column(JSON, default=list)
    shadow_label: Mapped[str | None] = mapped_column(String, nullable=True)
    shadow_confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    model_version: Mapped[str | None] = mapped_column(String, nullable=True)
    ts: Mapped[datetime] = _ts_col(index=True)
```

- [ ] **Step 5: Prune it with the raw history**

In `backend/app/retention.py`:
- Change the docstring sentence `raw status snapshots (one per status document), canonical readings and occupancy estimates would otherwise grow without bound.` to `raw status snapshots (one per status document), canonical readings, occupancy estimates and signature assessments would otherwise grow without bound.`
- Change the import to `from app.models import NodeStatus, OccupancyEstimate, SensorReading, SignatureAssessmentRow`.
- Change `_PRUNED = (NodeStatus, SensorReading, OccupancyEstimate)` to `_PRUNED = (NodeStatus, SensorReading, OccupancyEstimate, SignatureAssessmentRow)`.

- [ ] **Step 6: Add `classify_signature` to the analytics service**

In `backend/app/analytics/service.py`:
- Change the module docstring to `"""Analytics service: runs triangulation and the hazard signature classifier from live DB state."""`.
- Add `import logging` after `from __future__ import annotations`.
- Add these imports with the others:

```python
from app.analytics.signature import model as signature_model
from app.analytics.signature.features import extract_features, parse_snapshot
from app.analytics.signature.rules import SignatureAssessment, assess
from app.enums import NodeKind, SensorType
from app.models import Incident, Node, NodeStatus, SensorReading, SignatureAssessmentRow, Zone
```

(These replace the existing `from app.enums import SensorType` and `from app.models import Incident, SensorReading, Zone` lines.)
- After the imports, add:

```python
log = logging.getLogger("canary.signature")

# Seconds of an air node's status documents the signature classifier looks at.
SIGNATURE_WINDOW_S = 600
```

- Add this method at the end of `AnalyticsService`:

```python
    async def classify_signature(self, node_id: str, incident_id: str) -> SignatureAssessment | None:
        """Label an air node's recent window and store the assessment (with the shadow
        model's opinion) for the incident. None for nodes that are not air nodes."""
        node = await self.session.get(Node, node_id)
        if node is None or node.kind != NodeKind.air.value:
            return None
        since = datetime.now(timezone.utc) - timedelta(seconds=SIGNATURE_WINDOW_S)
        rows = (
            await self.session.scalars(
                select(NodeStatus)
                .where(NodeStatus.node_id == node_id, NodeStatus.ts >= since)
                .order_by(NodeStatus.ts.asc())
            )
        ).all()
        features = extract_features([parse_snapshot(_epoch(r.ts), r.payload) for r in rows])
        assessment = assess(features)
        shadow = signature_model.predict(features)
        if shadow is not None and shadow.label != assessment.label:
            log.info("signature %s: rules %s (%.2f), shadow %s (%.2f)", node_id, assessment.label,
                     assessment.confidence, shadow.label, shadow.confidence)
        self.session.add(SignatureAssessmentRow(
            incident_id=incident_id,
            node_id=node_id,
            label=assessment.label,
            confidence=assessment.confidence,
            scores=assessment.scores,
            evidence=assessment.evidence,
            shadow_label=shadow.label if shadow else None,
            shadow_confidence=shadow.confidence if shadow else None,
            model_version=shadow.model_version if shadow else None,
        ))
        return assessment
```

- [ ] **Step 7: Apply the hold and override rules in the incident service**

In `backend/app/incidents/service.py`:
- Add `import logging` after `from __future__ import annotations`.
- Add `from app.analytics.signature.rules import SignatureAssessment` next to the other `app.analytics` imports.
- After the imports, before `_TRIANGULATION_STATES`, add `log = logging.getLogger("canary.incidents")`.
- Replace this block in `handle_hazard_reading`:

```python
        target = decision.target_state
        reason = decision.reason
        fast_path = decision.fast_path
        if decision.reason == "corroborated" and assessment.suppress_escalation:
            target = IncidentState.verification
            reason = f"held_{assessment.classification}"
            fast_path = False
```

with:

```python
        # Hazard signature (air nodes): a fire signature cancels every hold; a confident
        # benign one may hold a corroborated escalation. Critical readings never reach
        # these branches (their reason is never "corroborated").
        signature = await self._classify_signature(incident, device_id)

        target = decision.target_state
        reason = decision.reason
        fast_path = decision.fast_path
        corroborated = decision.reason == "corroborated"
        if signature is not None and signature.overrides_hold:
            pass
        elif corroborated and assessment.suppress_escalation:
            target = IncidentState.verification
            reason = f"held_{assessment.classification}"
            fast_path = False
        elif corroborated and signature is not None and signature.allows_hold:
            target = IncidentState.verification
            reason = f"held_signature_{signature.label}"
            fast_path = False
```

- Add this method to `IncidentService`, directly after `_assess_false_alarm`:

```python
    async def _classify_signature(self, incident: Incident, device_id: str) -> SignatureAssessment | None:
        """Signature of the device's node; None for devices without one. Best-effort: a
        failure here must never change the safety path."""
        node_id, sep, _ = device_id.partition(":")
        if not sep:
            return None
        try:
            return await AnalyticsService(self.session).classify_signature(node_id, incident.id)
        except Exception:  # noqa: BLE001
            log.exception("signature classification failed for %s", device_id)
            return None
```

- [ ] **Step 8: Run the flow tests**

Run: `.venv/bin/python -m pytest tests/test_signature_flow.py -v`
Expected: 8 passed.

- [ ] **Step 9: Run the whole backend suite**

Run: `.venv/bin/python -m pytest -q`
Expected: all pass (the 101 existing tests plus the new ones). If an existing test fails, it is a behaviour change: read it before touching anything, and report it rather than editing the old test.

- [ ] **Step 10: Commit**

```bash
git add backend/app/models.py backend/app/retention.py backend/app/analytics/service.py backend/app/incidents/service.py backend/tests/signature_windows.py backend/tests/test_signature_flow.py
git commit -m "Classify air-node signatures on incidents and apply hold rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Incident API exposes the latest signature

**Files:**
- Modify: `backend/app/schemas.py` (add `SignatureOut`; add `signature` to `IncidentOut`)
- Modify: `backend/app/analytics/service.py` (add `latest_signatures`)
- Modify: `backend/app/api/routes.py` (the five routes that return incidents)
- Test: `backend/tests/test_signature_flow.py` (append)

**Interfaces:**
- Consumes: `SignatureAssessmentRow` and `AnalyticsService` (Task 5); `seed_history` and `publish` (Task 5).
- Produces:
  - `SignatureOut` (pydantic, `from_attributes`): `label: str`, `confidence: float`, `evidence: list[str]`, `shadow_label: str | None`, `shadow_confidence: float | None`, `model_version: str | None`, `ts: datetime`.
  - `IncidentOut.signature: SignatureOut | None = None`.
  - `AnalyticsService.latest_signatures(self, incident_ids: list[str]) -> dict[str, SignatureAssessmentRow]`.
  - In `routes.py`: `async _incidents_out(session: AsyncSession, incidents: list[Incident]) -> list[IncidentOut]`.

- [ ] **Step 1: Write the failing API tests**

Append to `backend/tests/test_signature_flow.py` (add `from tests.conftest import telemetry` next to the existing `auth_token` import):

```python
async def test_incident_api_returns_the_latest_signature(client):
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    sig = inc["signature"]
    assert set(sig) == {"label", "confidence", "evidence", "shadow_label", "shadow_confidence", "model_version", "ts"}
    assert (sig["label"], sig["confidence"]) == ("steam", pytest.approx(1.0))
    assert sig["evidence"][-1].endswith("→ steam")
    headers = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    one = (await client.get(f"/api/v1/incidents/{inc['id']}", headers=headers)).json()
    assert one["signature"] == sig


async def test_incident_without_assessment_has_null_signature(client):
    for seq in (1, 2):
        await client.post("/api/v1/telemetry", json=telemetry(
            "dev_gas_kitchen", "combustible_gas", 1200, zone_id="zone_kitchen", unit_id="unit_0312", seq=seq))
    [inc] = await _active(client)
    assert inc["signature"] is None


async def test_dismiss_returns_the_signature_too(client):
    await _publish_all(await seed_history("steam"))
    [inc] = await _active(client)
    headers = {"Authorization": f"Bearer {await auth_token(client, 'mihai')}"}
    r = await client.post(f"/api/v1/incidents/{inc['id']}/dismiss", headers=headers)
    assert r.status_code == 200, r.text
    assert r.json()["signature"]["label"] == "steam"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_signature_flow.py -k "signature or dismiss" -v`
Expected: the three new tests fail with `KeyError: 'signature'`.

- [ ] **Step 3: Add the schema**

In `backend/app/schemas.py`, directly before `class IncidentOut(BaseModel):`, add:

```python
class SignatureOut(BaseModel):
    """Latest hazard signature assessment for an incident. shadow_* is the shadow
    model's opinion only; it never affects the incident."""

    model_config = ConfigDict(from_attributes=True)
    label: str
    confidence: float
    evidence: list[str] = []
    shadow_label: str | None = None
    shadow_confidence: float | None = None
    model_version: str | None = None
    ts: datetime
```

Then add, as the last field of `IncidentOut` (after `benign_score`):

```python
    signature: SignatureOut | None = None
```

- [ ] **Step 4: Add the latest-per-incident query**

In `backend/app/analytics/service.py`, change `from sqlalchemy import select` to `from sqlalchemy import func, select`, and add this method to `AnalyticsService` after `classify_signature`:

```python
    async def latest_signatures(self, incident_ids: list[str]) -> dict[str, SignatureAssessmentRow]:
        """The newest assessment per incident, in one query (ids are monotonic)."""
        if not incident_ids:
            return {}
        newest = (
            select(func.max(SignatureAssessmentRow.id))
            .where(SignatureAssessmentRow.incident_id.in_(incident_ids))
            .group_by(SignatureAssessmentRow.incident_id)
        )
        rows = (await self.session.scalars(
            select(SignatureAssessmentRow).where(SignatureAssessmentRow.id.in_(newest))
        )).all()
        return {r.incident_id: r for r in rows}
```

- [ ] **Step 5: Fill `signature` in the incident routes**

In `backend/app/api/routes.py`, add `SignatureOut` to the `from app.schemas import (...)` list (keep it alphabetical), and add this helper directly above `@router.get("/buildings/{building_id}/incidents", …)`:

```python
async def _incidents_out(session: AsyncSession, incidents: list[Incident]) -> list[IncidentOut]:
    """Incidents with their latest hazard signature (one extra query for the batch)."""
    latest = await AnalyticsService(session).latest_signatures([i.id for i in incidents])
    out = []
    for incident in incidents:
        item = IncidentOut.model_validate(incident)
        row = latest.get(incident.id)
        item.signature = SignatureOut.model_validate(row) if row is not None else None
        out.append(item)
    return out
```

Then change the five routes:
- `list_incidents`: return annotation `-> list[IncidentOut]`; last line `return await _incidents_out(session, list((await session.scalars(q)).all()))`.
- `get_incident`: return annotation `-> IncidentOut`; last line `return (await _incidents_out(session, [incident]))[0]`.
- `dismiss_incident`, `order_evacuation`, `resolve_incident`: return annotation `-> IncidentOut`; replace the final `return incident` (after `await session.commit()`) with `return (await _incidents_out(session, [incident]))[0]`.

- [ ] **Step 6: Run the tests**

Run: `.venv/bin/python -m pytest -q`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add backend/app/schemas.py backend/app/analytics/service.py backend/app/api/routes.py backend/tests/test_signature_flow.py
git commit -m "Expose the latest hazard signature on incident responses

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Dashboard badge

**Files:**
- Modify: `web/src/api/types.ts`
- Create: `web/src/components/SignatureBadge.tsx`
- Modify: `web/src/views/DispatchView.tsx` (around line 92)
- Modify: `web/src/views/ManagerView.tsx` (around line 120)

**Interfaces:**
- Consumes: the `signature` field from Task 6.
- Produces: `export interface Signature` in `types.ts`; `Incident.signature: Signature | null`; `export function SignatureBadge({ signature }: { signature: Signature | null })`.

The web app has no unit-test runner; `npm run build` (tsc + vite) is the check.

- [ ] **Step 1: Add the type**

In `web/src/api/types.ts`, add above `export interface Incident`:

```ts
export interface Signature {
  label: string;
  confidence: number;
  evidence: string[];
  shadow_label: string | null;
  shadow_confidence: number | null;
  model_version: string | null;
  ts: string;
}
```

and add as the last field of `Incident` (after `benign_score`):

```ts
  signature: Signature | null;
```

- [ ] **Step 2: Create the badge**

Create `web/src/components/SignatureBadge.tsx`:

```tsx
import type { Signature } from "../api/types";

const LABELS: Record<string, { text: string; cls: string }> = {
  smouldering_fire: { text: "smouldering fire", cls: "alarm" },
  flaming_fire: { text: "flaming fire", cls: "alarm" },
  gas_leak: { text: "gas leak", cls: "alarm" },
  steam: { text: "steam", cls: "detection" },
  cooking: { text: "cooking", cls: "detection" },
  aerosol: { text: "aerosol / incense", cls: "detection" },
};

const pct = (value: number) => `${Math.round(value * 100)}%`;

/** Renders the hazard signature as a pill with its evidence on hover (null for normal/unknown). */
export function SignatureBadge({ signature }: { signature: Signature | null }) {
  if (!signature || signature.label === "normal" || signature.label === "unknown") return null;
  const m = LABELS[signature.label] ?? { text: signature.label.replace(/_/g, " "), cls: "" };
  const lines = [...signature.evidence];
  if (signature.shadow_label && signature.shadow_confidence !== null) {
    lines.push(`model (shadow): ${signature.shadow_label.replace(/_/g, " ")} ${pct(signature.shadow_confidence)}`);
  }
  return (
    <span className={`pill ${m.cls}`} title={lines.join("\n")} style={{ marginLeft: 6 }}>
      {m.text} · {pct(signature.confidence)}
    </span>
  );
}
```

- [ ] **Step 3: Show it next to the false-alarm badge**

In `web/src/views/DispatchView.tsx`, add `import { SignatureBadge } from "../components/SignatureBadge";` next to the `SignalBadge` import, and change:

```tsx
          <SignalBadge cls={incident.false_alarm_class} />
```

to:

```tsx
          <SignalBadge cls={incident.false_alarm_class} />
          <SignatureBadge signature={incident.signature} />
```

In `web/src/views/ManagerView.tsx`, add the same import, and change:

```tsx
                    <SignalBadge cls={inc.false_alarm_class} />
```

to:

```tsx
                    <SignalBadge cls={inc.false_alarm_class} />
                    <SignatureBadge signature={inc.signature} />
```

- [ ] **Step 4: Build**

Run from `RPISoftware/web`: `npm run build` (run `npm install` first if `node_modules` is missing).
Expected: tsc reports no errors and vite prints the built bundle.

- [ ] **Step 5: Commit**

```bash
git add web/src/api/types.ts web/src/components/SignatureBadge.tsx web/src/views/DispatchView.tsx web/src/views/ManagerView.tsx
git commit -m "Show the hazard signature on dashboard incidents

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Docs and the full smoke check

**Files:**
- Modify: `ARCHITECTURE.md` (the "As built" table row "Detection / analytics", and section "Module 3 — False-Alarm Reduction / Anomaly Detection")
- Modify: `docs/AI_IDEAS.md` (section "Hazard signature classifier")

- [ ] **Step 1: Update `ARCHITECTURE.md`**

In the "As built" table, replace the "Built" cell of the `Detection / analytics` row with:

```
§7 states without timers; rule-based triangulation, occupancy and false-alarm reduction; a rule-based hazard signature classifier per air node (smouldering/flaming fire, gas leak, steam, cooking, aerosol) that can hold a benign escalation or cancel a hold for fire, with a synthetic-trained random forest in shadow mode only; device thresholds and alarms applied under explicit safety rules ([`docs/HARDWARE.md`](./docs/HARDWARE.md) §2)
```

Directly under the `### Module 3 — False-Alarm Reduction / Anomaly Detection` heading, add:

```markdown
> **As built:** besides the single-channel shape classifier (`app/analytics/false_alarm.py`), each air node's 10-minute window is labelled by `app/analytics/signature/` using all of its channels: CO, gas, PM1/2.5/10, temperature, humidity and presence. A confident benign label (steam, cooking, aerosol) may hold a corroborated non-critical escalation in verification; a fire label cancels any hold; critical readings and node alarms are never held. A random forest trained on synthetic windows (`backend/tools/signature/`) runs in shadow mode, and its opinion is stored in `signature_assessments` next to the rules' label. Both encode untested assumptions: the thresholds need tuning against controlled tests on the real sensors. Design: [`docs/superpowers/specs/2026-10-09-hazard-signature-classifier-design.md`](../docs/superpowers/specs/2026-10-09-hazard-signature-classifier-design.md).
```

- [ ] **Step 2: Update `docs/AI_IDEAS.md`**

Directly under the `### Hazard signature classifier` heading, add:

```markdown
> **Status:** implemented as rules plus a shadow random forest. See `app/analytics/signature/` and the design in `docs/superpowers/specs/2026-10-09-hazard-signature-classifier-design.md` (repository root). The thresholds have not yet been validated on real sensors.
```

- [ ] **Step 3: Run the full smoke check**

Run from `RPISoftware`: `bash scripts/smoke.sh`
Expected: it ends with PASS (exit 0). The backend section runs every test, including the sklearn parity test if the train extra is installed in `.venv`.

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md docs/AI_IDEAS.md
git commit -m "Document the hazard signature classifier

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Report**

Report the three accuracy numbers from Task 4 Step 6, the final test count, and the smoke result. Repeat the known limit: the rules and the synthetic data share the same assumptions, so the numbers show consistency, not real-world accuracy.

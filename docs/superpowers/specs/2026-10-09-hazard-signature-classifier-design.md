# Hazard signature classifier — design

Date: 2026-10-09. Scope: the Raspberry Pi hub backend (`RPISoftware/backend`) and web
dashboard (`RPISoftware/web`). Idea source: `RPISoftware/docs/AI_IDEAS.md` §1.

## Goal

Label what is happening around an air node by combining all of its channels in one
time window, instead of judging each channel against its own threshold:
`smouldering_fire`, `flaming_fire`, `gas_leak`, `cooking`, `steam`, `aerosol`,
`normal`, or `unknown`. Each label carries a confidence and readable evidence.

A rule-based scorer makes the decisions. A random forest trained on synthetic data runs
alongside in **shadow mode**: its output is stored and logged so the two can be
compared, and no decision code reads it.

Success criteria:

- A corroborated, non-critical escalation caused by steam, cooking or aerosol is held in
  `verification`, with the signature label recorded.
- A fire signature cancels any hold, including one from the existing false-alarm layer.
- A critical reading or a node-raised alarm is never held or delayed.
- Managers and dispatchers see the label and evidence on the incident in the web
  dashboard.
- The Pi needs no new runtime dependencies.

## Context (as found)

- `app/analytics/false_alarm.py` classifies the shape of one channel's window. It runs
  from `IncidentService` (`app/incidents/service.py`), which stores `false_alarm_class`,
  `false_alarm_reason` and `benign_score` on the incident. It may hold a `corroborated`
  escalation in `verification` (`held_<class>`).
- Every accepted air status document is stored verbatim in `node_status`
  (`NodeStatus.payload`), one row per document at a 15 s cadence. Only CO, gas, PM2.5
  and presence become `SensorReading` rows; temperature, humidity, PM1 and PM10 exist
  only in the payload (`docs/HARDWARE.md` §2).
- Air-node device ids are `{node_id}:{channel}` (`Node` docstring,
  `ingestion/hardware.py`).
- The schema is created with `Base.metadata.create_all` and has no migrations. New
  columns on existing tables would never reach a database already on a Pi; new tables
  would.

## Components

All runtime code lives in `app/analytics/signature/` and is pure: no database access
and no I/O, apart from `model.py` reading its JSON file once.

### `features.py` — window → feature vector

Input: a list of `AirSnapshot`s (hub timestamp plus the parsed fields below), sorted by
time. Output: a `SignatureFeatures` dataclass with a fixed, ordered `FEATURE_NAMES`
tuple and `as_vector() -> list[float | None]`.

Fields read from each document: `co.ppm`, `gas.adc`, `particulate.pm1_0`,
`particulate.pm2_5`, `particulate.pm10`, `climate.temperature_c`,
`climate.humidity_percent`, `presence.detected`, and the warn thresholds `co.warn_ppm`,
`gas.warn_adc`, `particulate.warn_pm2_5` and `particulate.warn_pm10`. A channel whose
object is missing, has `valid: false`, or reports `state` `warmup` or `fault` is
treated as absent for that snapshot.

Definitions, per channel `c` in {co, gas, pm2_5, pm1_0, pm10}, over the snapshots where
`c` is present:

- `base_c`: the median of the earliest third of the samples (at least 2 samples).
- `peak_c`, `latest_c`: the maximum value and the last value.
- `rise_c = (peak_c − base_c) / warn_c`. PM1 uses `warn_pm2_5`. Clamped at ≥ 0.
- `decay_c = (peak_c − latest_c) / (peak_c − base_c)` when `peak_c > base_c`, else 0.
- `onset_s_c`: seconds from the last sample at or below `base_c + 0.1·warn_c` before
  the peak, to the peak.

Cross-channel and climate features:

- `rh_delta`: peak minus base relative humidity, in percentage points.
- `temp_delta`: peak minus base temperature, in °C.
- `temp_rate`: the largest temperature change over any 60 s span, in °C per minute.
- `fine_share = rise_pm1_0 / rise_pm2_5` and `coarse_share = rise_pm10 / rise_pm2_5`,
  computed when `rise_pm2_5 ≥ 0.1`.
- `presence_frac`: the share of snapshots with presence detected.
- `n_samples`, `span_s`.

A feature that cannot be computed is `None`, never 0. This keeps "sensor absent"
distinct from "flat".

### `rules.py` — features → assessment

`assess(features) -> SignatureAssessment` with `label`, `confidence` (0..1),
`scores: dict[label, float]` and `evidence: list[str]`.

Each label has **core** conditions (all must hold, or the score is 0) and
**supporting** conditions. Score = `0.5 + 0.5 × (supporting met / supporting total)`.
The label is the argmax and the confidence is its score.

| Label | Core | Supporting |
|---|---|---|
| `smouldering_fire` | `rise_pm2_5 ≥ 0.5`, `rise_co ≥ 0.3` | `decay_pm2_5 < 0.4`, `decay_co < 0.4`, `temp_rate < 2`, `rh_delta < 8` |
| `flaming_fire` | `temp_rate ≥ 2` or `temp_delta ≥ 8`; and `rise_pm2_5 ≥ 0.5` or `rise_co ≥ 0.3` | `decay_pm2_5 < 0.4`, `temp_delta ≥ 4`, `rise_co ≥ 0.3` |
| `gas_leak` | `rise_gas ≥ 0.5`, `rise_pm2_5 < 0.3` (or PM absent) | `decay_gas < 0.3`, `rise_co < 0.3`, `temp_delta < 2` |
| `steam` | `rh_delta ≥ 12`, `rise_pm2_5 ≥ 0.3`, `rise_co < 0.2` | `temp_delta < 4`, `coarse_share ≥ 1.0`, `presence_frac ≥ 0.3` |
| `cooking` | `rise_pm2_5 ≥ 0.3`, `rise_co < 0.6`, `presence_frac ≥ 0.3` | `0.5 ≤ temp_delta ≤ 6`, `3 ≤ rh_delta < 12`, `fine_share ≥ 0.6`, `decay_pm2_5 ≥ 0.3` |
| `aerosol` | `rise_pm2_5 ≥ 0.5`, `onset_s_pm2_5 ≤ 60`, `rise_co < 0.2` | `decay_pm2_5 ≥ 0.5`, `rh_delta < 8`, `temp_delta < 1` |

A condition on a `None` feature counts as not met. If that feature is in a core
condition, the label scores 0.

Fallbacks, applied in this order:

1. `n_samples < 4`, `span_s < 60`, or `pm2_5`, `co` and `gas` all absent → `unknown`,
   confidence 0.
2. Every label scores 0, every `rise_* < 0.3`, `rh_delta < 10` (or absent) and
   `temp_delta < 2` (or absent) → `normal`, confidence 0.8.
3. Every label scores 0 otherwise → `unknown`, confidence 0 (something changed that no
   signature explains).

Evidence: one short string per met condition of the winning label, plus a one-line
summary such as `"PM2.5 +140%, CO flat, humidity +22 pts → steam"`.

### `model.py` — shadow random-forest evaluator

Loads `app/analytics/signature/signature_model_v1.json` once, lazily, and caches it.
JSON layout:

```json
{"version": "v1", "feature_names": [...], "classes": [...],
 "trees": [{"feature": [...], "threshold": [...], "left": [...], "right": [...],
            "value": [[...], ...], "missing_left": [...]}]}
```

`predict(features) -> ShadowPrediction | None` walks each tree (go left when
`x ≤ threshold`; a `None` value follows `missing_left`), averages the leaf class
probabilities, and returns `label`, `confidence` and `model_version`. It returns
`None`, and logs once, when the file is missing or invalid or its `feature_names`
don't match `FEATURE_NAMES`.

### `backend/tools/signature/` — training (dev only)

A new optional extra in `pyproject.toml`: `train = ["numpy", "scikit-learn"]`. None of
this is imported by the app.

- `synth.py`: generates labelled windows per class (all eight labels, including
  `normal` and noisy `unknown`-style windows) as `AirSnapshot` lists at a 15 s cadence
  over 600 s. It uses parametric curves (onset time, rise amplitude, decay constant,
  humidity and temperature coupling, presence) with randomised parameters, sensor
  noise, and a random chance of dropping each channel. It runs with a fixed seed.
- `train.py`: synthesises the data, extracts features with the runtime `features.py`,
  trains `RandomForestClassifier(n_estimators=40, max_depth=6, random_state=0)`, and
  exports the JSON above. Missing values are imputed to a sentinel during training;
  `missing_left` is recorded per split. It prints holdout accuracy, a confusion matrix,
  and the rate of agreement with `rules.assess`.
- The exported model JSON is committed, so the Pi has no training step.

## Data flow

1. `IncidentService` evaluates a reading and gets `decision` from the detection engine,
   then the false-alarm `assessment` (both unchanged).
2. If the triggering device belongs to an air node (`{node_id}:{channel}` with a `Node`
   of kind `air`), `AnalyticsService.classify_signature(node_id)` loads that node's
   `node_status` rows from the last 600 s, parses them into `AirSnapshot`s, and runs
   `features → rules.assess` and `model.predict`.
3. A `SignatureAssessmentRow` is written to the new `signature_assessments` table:
   `id`, `incident_id`, `node_id`, `ts`, `label`, `confidence`, `scores` (JSON),
   `evidence` (JSON), `shadow_label`, `shadow_confidence`, `model_version`. The shadow
   result is also logged at INFO when it disagrees with the rules.
4. The hold decision (below) is applied, then the state transitions run as today.

Non-air devices (water nodes, the legacy simulator) skip steps 2–4.

`signature_assessments` rows are pruned by `app/retention.py` on the same 14-day
horizon as raw history.

## Authority and safety rules

Applied in `IncidentService` after the false-alarm assessment:

- Before the signature is considered: if the reading is critical or the node raised its
  own alarm, nothing is held (this is the existing behaviour and stays first).
- **Fire overrides holds:** if `smouldering_fire` or `flaming_fire` scores ≥ 0.6, any
  hold is cancelled, including a false-alarm `held_*`. The decision's target and reason
  are used unchanged. This never adds an evacuation or escalation beyond what the
  detection engine decided.
- **Benign hold:** if the decision reason is `corroborated`, the top label is `steam`,
  `cooking` or `aerosol` with confidence ≥ 0.7, and both fire scores are < 0.4, the
  target is held at `verification` with the reason `held_signature_<label>`.
- `unknown`, `normal` and `gas_leak` never cause a hold.
- The shadow prediction is never read by any of this.
- Any exception in steps 2–4 is caught and logged, and the flow continues exactly as if
  no signature existed.

The thresholds 0.6, 0.7 and 0.4 are module constants in `rules.py`.

## API and UI

- `IncidentOut` gains `signature: SignatureOut | None` with `label`, `confidence`,
  `evidence`, `shadow_label`, `shadow_confidence`, `model_version` and `ts`, taken from
  the latest assessment for the incident. Routes that return incidents fill it with one
  query that fetches the latest assessment per incident id (no relationship on
  `Incident`, so list views don't load full histories). WebSocket messages are
  unchanged; the dashboard already refetches incidents on transitions.
- Web: `api/types.ts` gains the type. A new `SignatureBadge` component (label and
  confidence, evidence in a tooltip or `title`) sits next to `SignalBadge` in
  `DispatchView.tsx` and `ManagerView.tsx`. The shadow label is shown only in the
  tooltip, marked "model (shadow)".
- The mobile app and resident views are unchanged.

## Testing

- `tests/test_signature_features.py`: base, rise, decay, onset and climate features on
  hand-built windows; invalid, warm-up and missing channels become `None`; short
  windows.
- `tests/test_signature_rules.py`: one scenario per label, each fallback, evidence
  strings.
- `tests/test_signature_model.py`: a tiny hand-written forest JSON (traversal, missing
  values, averaging); `None` on a missing or mismatched file; a parity test against
  sklearn's `predict_proba`, skipped when sklearn isn't installed.
- `tests/test_signature_flow.py`, end to end through hardware ingest, in the style of
  `test_false_alarm_flow.py`: a corroborated steam event is held as
  `held_signature_steam`; a smouldering event that the false-alarm layer would hold is
  not held; a critical reading during steam is not held; an exception inside the
  classifier leaves the flow unchanged; the incident API returns `signature`.
- `scripts/smoke.sh` passes, including the web build.

## Out of scope

- Using the shadow model for any decision.
- Learned per-room baselines, MQ5 temperature and humidity compensation, and
  cross-room fusion (separate ideas in `AI_IDEAS.md`).
- Firmware or TinyML changes, mobile app changes, and labelling tools for real data.

## Known limits

The rules and the synthetic training data both come from assumptions about how these
events look. Agreement between them shows consistency, not real-world accuracy. The
thresholds need tuning against controlled tests (toast, kettle, incense, lighter gas)
recorded on the real sensors. The docs (`ARCHITECTURE.md` §B.3 "As built" note and
`AI_IDEAS.md`) are updated to say so.

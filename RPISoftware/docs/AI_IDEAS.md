# AI Feature Ideas for Canary

Ideas for AI features that combine data from sensors across rooms, detect and locate
people, and track the spread of fire and other hazards.

## Starting point

The hub already has rule-based versions of three AI modules, and `ARCHITECTURE.md` §B
says these will become learned models later:

- `backend/app/analytics/triangulation.py`: a weighted-centroid estimate of where a leak started.
- `backend/app/analytics/false_alarm.py`: rules that judge the shape of a reading window.
- `backend/app/occupancy/service.py`: presence counts reconciled against resident check-ins.

Sensors available today: ZE03 CO, MQ5 gas (raw ADC), PMS5003T particulates plus
temperature and humidity, and LD2410 radar presence on the air node. The water node
has a leak probe and a valve relay.

## 1. Combining sensor data across rooms

### Hazard signature classifier

> **Status:** implemented as rules plus a shadow random forest. See `app/analytics/signature/` and the design in `docs/superpowers/specs/2026-10-09-hazard-signature-classifier-design.md` (repository root). The thresholds have not yet been validated on real sensors.

Instead of judging each value against its own threshold, classify a combined time
window per room:

| Event | Pattern across sensors |
|---|---|
| Smouldering fire | PM rises slowly, CO rises, temperature climbs slowly |
| Flaming fire | Temperature jumps, PM rises, fast rate of change |
| Cooking | PM, temperature and humidity rise; someone present; mealtime; clears in minutes |
| Gas leak | MQ5 rises, PM and CO stay flat |
| Shower steam | Humidity jumps and PM rises falsely (the PMS5003 counts water droplets as particles) |
| Aerosol or incense | Sharp PM spike, no CO, decays fast |

Gradient-boosted trees (e.g. LightGBM) on window features like slope, peak, decay time
and ratios between channels run easily on a Raspberry Pi. They can use the same
feature vector `false_alarm.py` already builds, which its docstring names as the ML
upgrade path.

### A per-room learned "normal"

A kitchen at 19:00 and a bedroom at 03:00 behave very differently. A seasonal baseline
or Isolation Forest per zone gives early "this is unusual for this room" warnings well
before fixed thresholds trip.

### ML compensation for the MQ5

MQ sensors drift strongly with temperature and humidity, and the same node already
measures both. A small regression that predicts the expected MQ5 ADC value from
temperature, humidity and time cuts drift false alarms, and the leftover difference is
a cleaner gas signal.

### Neighbour checks and virtual sensors

Treat the building as a graph of zones (rooms, doors, stairwells). Predict each sensor
from its neighbours and from its own other channels:

- Several neighbours rising in an order consistent with airflow points to a real event.
- One sensor jumping alone points to a fault or a local event.
- A slowly growing gap between prediction and reading means drift, which gives
  predictive maintenance for the MQ5 and the PMS fan.

## 2. Detecting and locating people

### Reading the LD2410 radar more closely

The radar reports energy per distance gate for moving and still targets, not just
presence. A small per-room classifier on that profile can tell an empty room from a
still person, a moving person, or a fan or curtain causing a false trigger. Counting
1 vs 2+ people is possible but rough.

### Tracking likely locations across rooms

Use an HMM or particle filter over the zone graph, where people can only move between
adjacent zones. This gives:

- A "last known presence" per zone. A bedroom that showed a still person before its
  node went offline in a fire is the top rescue priority.
- A probability map of where unaccounted residents are likely to be, not just a count.
  This feeds straight into `occupancy/service.py` and the responder view.

### Hardware add-ons that unlock more

- **SCD40 CO₂ sensor:** how fast CO₂ rises tracks how many people are in a room, and it
  also detects combustion.
- **Breathing-capable mmWave radar** (e.g. a 60 GHz module): detects still or sleeping
  people and falls, which matters for elderly residents.
- **ESP32 Wi-Fi CSI sensing:** already in the plan; presence detection without cameras,
  but research-grade accuracy.

## 3. Locating hazards and predicting spread

### Simulate fires to get training data

Real fire data can't be collected. NIST CFAST is a zone-based fire model, which matches
room-level sensors well. Model the floor plan in it, simulate thousands of fires with
varied origin, fuel and door states, and record what each virtual sensor would read.
Train models on that synthetic data, then check them against real controlled tests
(toast, incense, steam).

### Probabilistic source location

Replace the weighted centroid with Bayesian inversion: candidate sources × release
rates, a forward model (diffusion over the zone graph, or the CFAST-trained model), and
a posterior given the observed arrival times and levels. The output is a probability
heatmap with honest uncertainty. It can keep the same interface as `triangulation.py`.

### Spread forecast

Update a per-zone state (clear / smoke / heat / fire) with a Kalman or particle filter
as sensors trip, then forecast forward. Example output: "Smoke expected in stairwell B
in about 4 minutes; stairwell A clear for 10+."

### Dynamic evacuation routing

Combine the spread forecast with occupancy and compute time-dependent safest paths:
avoid any zone predicted to be compromised by the time a person would reach it. Push
per-unit routes to the Flutter app through the existing `EvacuationRoute` model, and
give responders a ranked rescue list (where people probably are × how dangerous that
zone is).

### Water spread

A leak on floor 4 means the units directly below are at risk. Notify them, and
optionally let corroborated detection close the valve. With a flow meter, small
continuous overnight flow can also be caught, which is a classic hidden leak.

## 4. Building-level and operations

### Incident briefing for responders

An LLM turns the structured incident timeline into a short Romanian brief for ISU or
the alarm-receiving centre, for example: "Fire likely started in the kitchen of
apartment 12 around 03:14. Smoke reached the stairwell at 03:17. Two residents
unaccounted; last radar presence in the apartment 14 bedroom." It should be generated
only from database facts and never be in the alarm path. Use a cloud model when online
and a small local model (llama.cpp on the Pi) as an offline fallback.

### Learning from manager feedback

When a manager marks an incident as a false alarm or genuine, store that as a training
label. The labelled dataset then grows from real use (active learning).

### TinyML on the ESP32-S3

Run a compact version of the signature classifier on the node with TFLite Micro or
Edge Impulse, so early warnings still work when the Pi is down.

### Comfort and health extras

Mould and condensation risk from dew point, and air-quality trends. These aren't safety
features, but they give residents a daily reason to keep the app installed.

## Guardrails for a life-safety system

- **AI only adds or upgrades alerts.** It never suppresses a critical reading or an
  alarm the node raised itself. `false_alarm.py` already enforces this; keep it as a
  hard rule for every model.
- **Run new models in shadow mode first.** Log what they would have done next to what
  the rules did, and measure the false-negative rate before letting them affect
  anything.
- **Data sources:** CFAST/FDS simulations, controlled safe experiments, public datasets
  (e.g. the Kaggle smoke detection dataset), and manager feedback labels.

## Suggested starting order

These three give the best demo for the effort:

1. **Hazard signature classifier.** Very visible ("it knew it was toast, not fire") and
   reuses the existing feature code.
2. **Spread forecast plus dynamic evacuation routing.** Present it as an animated floor
   plan on the dashboard.
3. **Probabilistic "last known presence" map** for responders.

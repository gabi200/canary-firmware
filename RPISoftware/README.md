# Canary 🐤

**Smart Building Safety & Hazard-Response Platform** for multi-unit residential buildings
(Romanian HOA / *asociații de proprietari* context).

Canary connects to an in-building IoT sensor network (combustible gas, CO, water-leak,
WiFi-presence) and drives the safety-critical path:

> **detection → alert → evacuation → victim-accounting**

The full architecture & delivery plan lives in **[`ARCHITECTURE.md`](./ARCHITECTURE.md)**.
This repo currently contains the **Backend MVP + sensor simulator** — the core of the
plan, runnable end-to-end with **no hardware**.

---

## What's built (MVP slice)

```
backend/        FastAPI service
  app/
    enums.py            canonical wire/DB/API vocabularies (single source of truth)
    config.py           env config (CANARY_* )
    db.py               async SQLAlchemy + Timescale hypertables (Postgres) / SQLite (dev)
    models.py           data model (ARCHITECTURE.md §6)
    schemas.py          canary.telemetry.v1 wire contract + API DTOs
    detection/          pure threshold + decision engine (§B, §7 guards)
    incidents/          pure state machine + orchestration service (§7)
    occupancy/          occupancy estimate + victim-accounting (§B)
    notify/             notification fan-out (stub: persists + WebSocket broadcast)
    ingestion/          transport-agnostic pipeline + MQTT consumer (§5)
    realtime/           WebSocket connection manager (per-building rooms)
    api/                REST + WebSocket routes (§A.5)
    security.py         JWT auth + RBAC
    seed.py             demo building bld_007 (sensors, users, ARC)
    main.py             app wiring + lifespan
  tests/                pure-logic + API/flow tests
simulator/      MQTT sensor simulator (publishes canary.telemetry.v1)
docker-compose.yml      TimescaleDB + Redis + EMQX + backend + simulator
```

## Quickstart (Docker)

```bash
docker compose up -d --build           # Timescale + Redis + EMQX + backend
open http://localhost:8000/docs        # OpenAPI

# drive the full path with fake sensors (gas leak -> critical -> evacuation):
docker compose run --rm simulator --scenario gas_leak
#   other scenarios: presence | co | water_leak | normal
```

Watch live incidents over WebSocket (get a token first):

```bash
TOKEN=$(curl -s localhost:8000/api/v1/auth/token -H 'content-type: application/json' \
  -d '{"username":"mihai"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

# any WS client, e.g. websocat:
websocat "ws://localhost:8000/api/v1/ws/incidents?building_id=bld_007&token=$TOKEN"
```

## Quickstart (no Docker — SQLite + HTTP ingest)

```bash
cd backend
python3 -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"
export CANARY_DATABASE_URL="sqlite+aiosqlite:///./canary.db"
export CANARY_MQTT_ENABLED=false
uvicorn app.main:app --reload
# then POST telemetry to /api/v1/telemetry (same pipeline as MQTT) — see tests for payloads
```

## Demo accounts (seeded, dev token by username)

| username | role | can |
|---|---|---|
| `ana` | resident | check in ("I'm safe"), see status |
| `mihai` | hoa_manager | dashboard, incidents, accounting, dismiss/evacuate/resolve |
| `dispecer` | dispatcher_external | incident-centric view, accounting |
| `admin` | system_admin | everything |

## Key endpoints

| Method | Path | Role |
|---|---|---|
| POST | `/api/v1/auth/token` | public (dev) |
| GET | `/api/v1/buildings/{id}/incidents?active=true` | any |
| GET | `/api/v1/incidents/{id}/events` | any |
| GET | `/api/v1/incidents/{id}/accounting` | manager / dispatcher |
| POST | `/api/v1/incidents/{id}/checkin` | resident |
| POST | `/api/v1/incidents/{id}/dismiss` \| `/order-evacuation` \| `/resolve` | manager / dispatcher |
| POST | `/api/v1/telemetry` | dev ingress (prod = MQTT) |
| WS | `/api/v1/ws/incidents?building_id=&token=` | authenticated |

## Tests

```bash
cd backend
pip install -e ".[dev]"
pytest -q
```

- `test_state_machine.py`, `test_detection.py` — pure logic, no DB.
- `test_ingestion_dedupe.py` — `(device_id, epoch, seq)` dedupe + **reboot regression**.
- `test_incident_flow.py` — critical gas → `evacuation`, check-in → unaccounted count drops, RBAC.

## Web — Operations dashboard (React)

`web/` — role-based console (React + TS + Vite): **Manager/HOA** view (floor plan, live
sensor status, trends, device health, incident actions) and **Dispatch/emergency-services**
view (hazard source on floor plan, occupancy + unaccounted count, evacuation progress,
timeline). Live over WebSocket. See [`web/README.md`](./web/README.md).

## Mobile — Flutter resident app

`mobile/` — resident app (Flutter): emergency alerts, evacuation guidance routed away
from the hazard, and "I'm safe" check-in feeding victim-accounting. Talks to this
backend over REST + WebSocket. See [`mobile/README.md`](./mobile/README.md) to run it.

## AI hazard-source triangulation

`backend/app/analytics/` — estimates the leak origin from the sensor array
(concentration-weighted centroid + time-of-first-detection, optional airflow prior),
with an honest confidence score (capped at 0.95; single-sensor degrades to zone-level).
Runs from `verification` onward for gas/CO; exposed at
`GET /api/v1/incidents/{id}/triangulation` and surfaced on the dashboard floor plan
(SOURCE marker + confidence) and the Dispatch "Hazard source (AI)" card. The estimate
can differ from the first-detection zone (it follows the concentration peak).

## False-alarm reduction

`backend/app/analytics/false_alarm.py` — classifies a sensor's recent reading window
(spike-and-decay, oscillatory cooking, sensor drift, sustained-genuine, sub-threshold
micro-leak trend) and may **hold a corroborated-by-count, non-critical signal in
`verification`** instead of alarming — e.g. a lone sensor sitting flat just over
threshold. Real cross-sensor corroboration (a second device/zone) or a clearly rising
trend escalates as genuine. **Critical readings and edge alarms are never suppressed.**
Slow sub-threshold rises open a low-severity **advisory** incident (managers only).
Assessment shown on the dashboard (signal badge); rule-based now, same features feed
an ML upgrade later (ARCHITECTURE.md §B.3).

## Not yet built (see ARCHITECTURE.md roadmap §F)

Real FCM/APNs delivery (wired but off by default; needs Firebase config), LoRa gateway
tier, tamper-evident audit hash-chaining, alembic migrations, external dispatch adapters.
The backend notification layer is a stub (persists + WebSocket broadcast); transports
plug in behind it. Occupancy/victim-accounting is basic (rule-based) — the ML upgrade
paths are described in ARCHITECTURE.md §B.

> ⚠️ MVP detection thresholds are illustrative engineering defaults, **not** certified
> life-safety setpoints. Canary is an advisory system in this slice — not a substitute
> for certified gas/CO alarms.

# Canary — Smart Building Safety & Hazard-Response Platform
## Architecture & Delivery Plan

> Buildable implementation plan: architecture, tech stack, data models, API contracts, AI/analytics approach, and a phased roadmap. Greenfield design deliverable. Multi-unit residential buildings; Romanian HOA / "asociatii de proprietari" context; emergency services = 112/ISU.

**Contents:** As built (Raspberry Pi hub); Foundation; A) Backend; B) AI & Analytics; C) Web Dashboard; D) Mobile App; E) Cross-Cutting (Logging, Security, Integration, NFRs); F) Roadmap; G) Open Questions & Trade-offs.

## As built (Raspberry Pi hub)

Everything after this section is the design and delivery **plan**. What exists today is a single-building hub on one Raspberry Pi (this directory), fed by the ESP32 firmware in `../air_sensor` and `../water_sensor`. How to run it: [`README.md`](./README.md) and [`RUNME.md`](./RUNME.md). The firmware ↔ hub contract: [`docs/HARDWARE.md`](./docs/HARDWARE.md). Checks and troubleshooting: [`DEBUG.md`](./DEBUG.md). Sections of the plan that differ from the build carry an **As built** note; everything else in them is still planned, not delivered.

| Area | Plan | Built |
|---|---|---|
| Edge nodes | ESP32-S3 per zone on ESP-IDF + TFLite Micro: gas, CO, leak, Wi-Fi presence; MQTT over TLS, LoRa fallback | Arduino-core firmware for two nodes. Air (ESP32-S3): ZE03 CO, MQ5 gas (raw ADC, not ppm), PMS5003T particulates + temperature/humidity, LD2410 radar presence, LED + buzzer. Water (ESP32-C3): leak probe, valve relay, buzzer. Both grade readings against their own thresholds; plaintext MQTT; no LoRa, no Wi-Fi presence sensing |
| MQTT topics / payload | `canary/v1/{building}/.../{device}/telemetry` carrying `canary.telemetry.v1` (§5) | Retained `<base>/status` documents and `<base>/availability`; the hub translates each status into `canary.telemetry.v1` readings. `canary/v1/.../telemetry\|event` is still accepted (legacy simulator) |
| Broker | Mosquitto per gateway, bridged to a cloud EMQX cluster; mTLS + per-device ACL | Mosquitto 2 on the Pi; login required, one MQTT user per sensor (named like its base topic); per-device ACL optional, off by default. No EMQX, no bridge |
| Tiers | Edge → per-building gateway (local panel, signage, LAN/BLE check-in, store-and-forward) → multi-AZ cloud | Edge → one Pi running broker, backend and dashboard with `docker compose`. No gateway panel or signage, no cloud |
| Backend | Separate services over Redis Streams, Postgres-before-ack | One FastAPI process: MQTT consumer, detection, incident state machine, analysis, REST + WebSocket |
| Storage | PostgreSQL 16 + TimescaleDB + Redis 7 | SQLite (WAL) on a Docker volume by default; Postgres optional (hypertables only if Timescale is installed). No Redis. Raw history pruned hourly after 14 days |
| Detection / analytics | §7 machine with timers; learned triangulation, occupancy and false-alarm models (§B) | §7 states without timers; rule-based triangulation, occupancy and false-alarm reduction; device thresholds and alarms applied under explicit safety rules ([`docs/HARDWARE.md`](./docs/HARDWARE.md) §2) |
| Notification / escalation | FCM/APNs, SMS, email, signed webhooks to ARC, ISU and the gas distributor | `Notification` rows + WebSocket only; FCM optional in the app and off by default; no external adapters |
| Web / mobile | React with Zustand, Konva, ECharts, OIDC; Flutter with FCM and a gateway LAN/BLE path | React + TanStack Query + SVG + Recharts; Flutter + Riverpod over REST + WebSocket to the Pi; username-only dev login |
| Security | TLS/mTLS everywhere, OIDC, per-device certificates, hash-chained audit | Plaintext MQTT/HTTP on a trusted LAN/VLAN; per-sensor MQTT passwords; plain append-only audit table |
| Device commands | Valve / alarm-test on `cmd` topics | Not sent yet (the firmware's `<base>/valve/set` and `<base>/buzzer/set` exist) |
| Operations | Kubernetes, CI/CD, Prometheus/Grafana/OpenTelemetry/Loki | `docker compose` with `restart: unless-stopped` and bounded logs; `scripts/smoke.sh` as the test gate |

Status: covered by the backend test suite and a firmware-accurate simulator, not yet run on a physical Pi with the real sensors. Known limitations: [`README.md`](./README.md).

---

## 1. Executive Summary & Core Design Principles

**Executive summary.** This platform turns a multi-unit residential building (Romanian *asociație de proprietari*) into a self-defending safety system: integrated edge sensors (combustible gas, CO, water-leak, WiFi-presence) on ESP32-S3 nodes stream telemetry over MQTT (with a LoRa/mesh fallback) to a per-building gateway and a cloud backend that detects hazards, opens **Incidents**, and drives a strict **detection → alert → evacuation → victim-accounting** path. Three audiences are served from one incident model: **residents** get push alerts and evacuation guidance plus a check-in flow, **building managers/HOA** get a web monitoring console, and **monitoring/escalation partners** (a 24/7 alarm-receiving center that calls 112/ISU, plus gas distributors ENGIE/Distrigaz Sud) receive escalated, machine-readable incidents. Two differentiators sit on top of the same data: **AI hazard-source triangulation** (locating the likely leak origin from multi-sensor gradients) and **presence-based unaccounted-occupant accounting** (reconciling WiFi-presence occupancy estimates against resident check-ins so first responders know who is still inside). The system is engineered so that life-safety functions degrade gracefully **at every stage of the path, not only the first**: even with no cloud, the per-building gateway sustains a minimum-viable directed evacuation and a degraded unaccounted-occupant count; and even with no cloud *and* no gateway, an edge node sounds a local alarm.

**Core design principles.**

- **Safety-first ordering.** The detection → alert → evacuation → victim-accounting path outranks every other concern (features, cost, analytics, privacy reporting). Any change that adds latency or failure modes to this path is rejected by default.
- **Edge autonomy / fail-safe local alarm.** Each ESP32-S3 node runs on-device pre-inference and can trigger a local audible/visual alarm and relay-driven gas cutoff **without** the gateway or cloud. Loss of connectivity must never silence a real hazard; the node fails *loud*, not silent.
- **Gateway-resident degraded path (every stage degrades, not just alerting).** The per-building gateway is a second autonomous tier that keeps stages 2–4 alive when the WAN is down. It (a) raises the building-wide local alarm panel, (b) drives cached directional evacuation signage that routes occupants *away from the alarming zone*, and (c) collects resident check-ins locally and computes a degraded unaccounted count. The detection → alert → evacuation → victim-accounting path therefore never collapses to a "dumb klaxon"; it degrades in fidelity, not in stages. The exact per-mode outputs are specified in §8.
- **Defense in depth.** Independent layers (edge thresholds, gateway corroboration, cloud AI verification, human/manager confirmation, external escalation) each can raise an alarm. No single component failure suppresses an alert; redundant alarm paths (cloud push + edge siren + gateway local notify) cover each other.
- **Building-internal alerting is never gated on corroboration.** Corroboration (a second sensor or cloud AI agreement) gates only false-alarm-sensitive *outward* actions — external dispatch and gas-valve actuation. It never gates waking the building. A single node at its critical threshold raises the building-wide panel on its own (see §7 and §8).
- **Human-mediated emergency escalation is the default.** The platform does not assume a machine-to-machine 112/ISU dispatch API; none exists by default in Romania. The primary, always-present escalation target is a contracted 24/7 alarm-receiving center (ARC) or duty manager obligated to phone 112. A machine-readable webhook to ISU is an *optional enhancement*, enabled only where a signed ISU integration agreement exists (see §7 and §9).
- **Privacy-vs-life-safety balance.** WiFi-presence is processed as **anonymous occupancy counts/estimates per zone** (CSI/RSSI features, never packet payloads, never persistent device-identity tracking) under normal operation. Identity-level resolution is gated: it is only unlocked, audited, and time-boxed when an **Incident** reaches `alarm`/`evacuation`, strictly to support victim-accounting. All such unlocks are recorded in `AuditLogEntry`.

---

## 2. System Architecture

> **As built:** no gateway tier and no cloud. One Raspberry Pi runs Mosquitto, the backend and the dashboard; the data stores are SQLite by default (Postgres optional) instead of PostgreSQL + TimescaleDB, and there is no Redis. See "As built" at the top.

**Component breakdown.**

- **Edge layer (`Device`/`Sensor` nodes).** ESP32-S3 nodes per `Zone`: combustible-gas (MEMS/electrochemical), CO, water-leak, WiFi-presence (CSI/RSSI). On-device pre-inference, local alarm driver (siren/strobe + optional solenoid gas-valve relay), MQTT client over WiFi, LoRa radio for fallback.
- **Per-building gateway.** Industrial edge box per building. Runs a local MQTT broker (store-and-forward), LoRa concentrator, edge corroboration logic, and a **local alarm panel**. Holds cached `EvacuationRoute`/`AssemblyPoint` geometry and the last buffered `OccupancyEstimate` snapshot, and exposes a **LAN/BLE local API** the Flutter app uses when the WAN is down. Buffers telemetry when WAN is down; can independently fan out a building-wide alarm, drive directional evacuation signage that routes away from the alarming zone, collect check-ins locally, and compute a degraded unaccounted count.
- **Cloud MQTT broker.** EMQX cluster — TLS, per-device auth, bridged from each gateway broker.
- **Ingestion service.** Subscribes to broker, validates schema, dedupes (see §5), writes `SensorReading` to the time-series store and hot values to cache.
- **Backend services.** Detection/Verification engine, Incident orchestrator (state machine §7), AI triangulation service, Occupancy/Accounting service, Notification service, Escalation/External-integration service, Identity/RBAC, Audit.
- **Data stores.** PostgreSQL (relational/system-of-record), TimescaleDB (time-series), Redis (cache + queues/streams).
- **API gateway.** Authenticated REST + WebSocket/SSE for live incidents; webhook egress for external integrations.
- **Clients.** Web console (managers/HOA), Flutter mobile app (residents; talks to cloud over WAN and to the per-building gateway over LAN/BLE when WAN is down), external connectors (ARC/112-ISU, gas distributors).

```
                                  EDGE-LOCAL ALARM PATH  (works with NO cloud / NO gateway)
                                  ┌─────────────────────────────────────────────────────┐
                                  │  ESP32-S3 on-device pre-inference -> local siren/     │
                                  │  strobe + gas-valve relay  (fail-loud)                │
                                  └─────────────────────────────────────────────────────┘
                                                    ▲
   ┌──────────────────────────┐                    │ (autonomous)
   │  EDGE NODES per Zone      │────────────────────┘
   │  gas / CO / leak /        │
   │  WiFi-presence (ESP32-S3) │◄───────────────┐
   └───────────┬──────────────┘                 │ Flutter LAN/BLE
               │ MQTT/TLS (primary, WiFi)        │ local check-in
               │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─►  LoRa / mesh  (FALLBACK when WiFi down)
               ▼                                       │
   ┌──────────────────────────────────────────────────▼───────────┐
   │  PER-BUILDING GATEWAY  (degraded path for ALL 4 stages)       │
   │   • local MQTT broker (store-and-forward buffer)              │
   │   • LoRa concentrator   • edge corroboration                  │
   │   • LOCAL ALARM PANEL (building-wide, cloud-independent) ◄──── building-local alert path
   │   • cached EvacuationRoute/AssemblyPoint -> directional signage│
   │   • LAN/BLE check-in API + buffered OccupancyEstimate         │
   │     -> degraded unaccounted count                             │
   └───────────┬──────────────────────────────────────────────────┘
               │ MQTT bridge / TLS (WAN)
               ▼
   ┌──────────────────────────┐
   │  CLOUD MQTT BROKER (EMQX) │
   └───────────┬──────────────┘
               ▼
   ┌──────────────────────────┐     ┌───────────────────────────────────────────────┐
   │  INGESTION SERVICE        │────►│ DATA STORES                                    │
   │  validate / dedupe / route│     │  PostgreSQL (SoR) · TimescaleDB (TS) · Redis   │
   └───────────┬──────────────┘     └───────────────────────────────────────────────┘
               ▼
   ┌───────────────────────────────────────────────────────────────┐
   │  BACKEND SERVICES                                               │
   │  Detection/Verification · Incident Orchestrator (state machine)│
   │  AI Triangulation · Occupancy/Accounting · Notification        │
   │  Escalation/External · Identity-RBAC · Audit                   │
   └───────────┬───────────────────────────────────────────────────┘
               ▼
   ┌──────────────────────────┐
   │  API GATEWAY             │  REST + WebSocket/SSE + webhooks
   └───┬───────────┬──────────┘
       ▼           ▼                 ▼
 ┌──────────┐ ┌──────────┐  ┌────────────────────────────┐
 │ WEB      │ │ FLUTTER  │  │ EXTERNAL: ARC/112-ISU,      │
 │ console  │ │ mobile   │  │ ENGIE/Distrigaz Sud         │
 │ (HOA)    │ │(residents│  │ (escalated incidents)       │
 └──────────┘ └──────────┘  └────────────────────────────┘
```

---

## 3. Data-Flow Overview

> **As built:** each sensor publishes retained `<base>/status` documents to Mosquitto on the Pi. The backend stores every document raw, turns it into readings, drops duplicates by `(device_id, epoch, seq)` in the database and runs detection in the same process. Alerts reach the dashboard and the app over the WebSocket; check-ins go to the Pi's REST API over the LAN. There is no gateway panel, bridge, EMQX, TimescaleDB or Redis on this path.

**Telemetry path.** `Device` samples → on-device pre-inference → publish JSON to MQTT (`.../telemetry`) → gateway broker (buffers if WAN down) → bridge to cloud EMQX → **Ingestion** validates + dedupes on `(device_id, epoch, seq)` → writes `SensorReading` to TimescaleDB, updates latest value + rolling features in Redis → **Detection** consumes the stream and evaluates per-sensor thresholds and cross-sensor gradients.

**Alert / escalation path.** Detection crosses a guard → `Incident` opens at `detection` → Verification corroborates (neighboring zones, edge corroboration flag, AI triangulation) → on confirmation, transition to `alarm`: Notification fans out resident push + manager web push, gateway raises local alarm panel, edge nodes already self-alarming. Persistence/severity guard → `escalation`: Escalation service notifies the contracted ARC/duty manager (the always-present primary target, obligated to call 112/ISU) and the relevant gas distributor; where a signed ISU agreement exists, an optional machine-readable webhook is also sent. `evacuation` activates `EvacuationRoute`/`AssemblyPoint` guidance. Every transition writes an `IncidentEvent` + `AuditLogEntry`. **Edge-local alert path runs in parallel and unconditionally** — it never waits on the cloud — and the **gateway degraded path** (directional evacuation signage + local check-in + degraded accounting) runs whenever the WAN is down.

**Resident check-in path.** On `alarm`/`evacuation`, Notification sends each resident a "Are you safe?" prompt (Flutter push + actionable notification). Resident responds → `CheckIn` (status: `safe_outside` / `safe_inside` / `needs_help` / `no_response`) → Occupancy/Accounting reconciles `CheckIn` records against per-zone `OccupancyEstimate` (from WiFi-presence) to compute **unaccounted occupants**, surfaced live to managers and to the ARC/ISU escalation channel. When the WAN is down, the Flutter app submits the same `CheckIn` to the **gateway's LAN/BLE API**; the gateway reconciles those against its last-buffered `OccupancyEstimate` snapshot to produce a **degraded unaccounted count** on the local panel, and the cloud re-reconciles on recovery.

---

## 4. Recommended Tech Stack

**Backend choice — Python/FastAPI is selected over Node/NestJS.** Rationale: the differentiators (AI hazard-source triangulation, presence/occupancy reconciliation, signal-feature processing) are data/ML-heavy and live in the Python ecosystem (NumPy/pandas/scikit-learn/ONNX Runtime, plus the same toolchain used to train the on-device ESP32 pre-inference models). FastAPI gives first-class async (MQTT consumers, WebSocket incident streams), Pydantic schema validation that we reuse verbatim as the telemetry contract (§5), and strong OpenAPI generation for the Flutter and external clients. NestJS is excellent for I/O orchestration but would split the codebase across two language ecosystems for the ML path; one Python stack keeps the safety-critical inference logic unified.

| Layer | Technology | One-line justification |
|---|---|---|
| Edge / firmware boundary | ESP32-S3 + ESP-IDF (C), TensorFlow Lite Micro, MQTT (TLS) + LoRa fallback | On-device pre-inference and fail-loud local alarm; the firmware boundary is the JSON/LoRa message contract in §5. |
| Messaging | EMQX (cloud cluster) + Mosquitto on each gateway, bridged | EMQX scales with per-device auth/ACL and rules; gateway Mosquitto gives local store-and-forward when WAN drops. |
| Backend | Python 3.12 + FastAPI | Async + Pydantic contracts + unified ML ecosystem for triangulation/occupancy (see choice above). |
| Time-series store | TimescaleDB (PostgreSQL extension) | Hypertables + continuous aggregates for `SensorReading`/`DeviceHealth`; same engine as relational store cuts ops surface. |
| Relational store | PostgreSQL 16 | System-of-record for all config/entities/incidents with strong constraints and auditability. |
| Cache / queue | Redis 7 (+ Redis Streams) | Hot latest-values and rolling features for sub-second detection; Streams as the internal work queue for detection/notification. |
| Frontend (web) | React 18 + TypeScript + Vite, TanStack Query, WebSocket | Live incident console with real-time updates for HOA/manager monitoring. |
| Mobile | Flutter (Dart) + Firebase Cloud Messaging; LAN/BLE client to gateway | Single codebase iOS/Android resident app; FCM for cloud-path push, gateway LAN/BLE for check-in when WAN is down. |
| Infra / deploy / observability | Docker + Kubernetes (managed), GitHub Actions CI/CD, Prometheus + Grafana, OpenTelemetry, Loki | Reproducible deploys and end-to-end latency SLO monitoring for the safety path. |

> **As built:** the backend row stands (Python 3.12 + FastAPI). Edge: Arduino ESP32 core, threshold grading on the device, plaintext MQTT, no TensorFlow Lite Micro, no LoRa. Messaging: Mosquitto 2 on the Pi only. Stores: SQLite by default, Postgres optional (Timescale hypertables only if the extension is present); Redis is not used. Web: TanStack Query + native WebSocket, SVG floor plan, Recharts (no Zustand, Konva or ECharts). Mobile: FCM optional and off by default, no gateway LAN/BLE client. Infra: `docker compose` on one Pi; no Kubernetes, CI/CD pipeline or observability stack.

---

## 5. Sensor Message Schema

> **As built:** the real firmware does not publish this schema. Each ESP32 publishes a retained JSON status document on `<base>/status` (plus `<base>/availability`), and the hub translates it into `canary.telemetry.v1` readings, one per channel ([`docs/HARDWARE.md`](./docs/HARDWARE.md) §1–2). In those readings `epoch` is the hub's boot counter for the node and `seq` the device uptime in ms; there is no `device_ts` (the devices have no wall clock); an optional `thresholds` object carries the device's own calibration. The hub's schema also adds the sensor types `particulate` and `radar_presence`. This JSON is sent directly only by the legacy simulator (`.../telemetry` and `.../event` topics) and to the HTTP ingress `POST /api/v1/telemetry`. The `health`, `cmd` and `gateway/status` topics and the LoRa/CBOR variant are not built.

**MQTT topic hierarchy.** Lowercase, slash-delimited, IDs are stable identifiers (not human labels):

```
canary/v1/{building_id}/{floor_id}/{unit_id}/{zone_id}/{device_id}/telemetry
canary/v1/{building_id}/{floor_id}/{unit_id}/{zone_id}/{device_id}/health
canary/v1/{building_id}/{floor_id}/{unit_id}/{zone_id}/{device_id}/event      # edge-detected hazard / local-alarm fired
canary/v1/{building_id}/cmd/{device_id}                                       # downlink: config, alarm-test, valve cmd
canary/v1/{building_id}/gateway/status                                        # gateway heartbeat / WAN state
```

- `unit_id` for common areas (hallway, basement, stairwell) is the reserved value `common`.
- Telemetry/health/event are device→cloud; `cmd` is cloud→device.

**JSON telemetry payload.**

```json
{
  "schema": "canary.telemetry.v1",
  "device_id": "dev_8f3a21",
  "sensor_type": "combustible_gas",
  "location": {
    "building_id": "bld_007",
    "floor_id": "flr_03",
    "unit_id": "unit_0312",
    "zone_id": "zone_kitchen"
  },
  "value": 1850,
  "units": "ppm",
  "edge_state": "warn",
  "edge_inference_score": 0.81,
  "signal": { "rssi": -67, "snr": 9.5, "link": "wifi" },
  "health": { "status": "ok", "self_test": "pass" },
  "battery": { "level_pct": 88, "powered": "mains", "low_battery": false },
  "fw_version": "1.4.2",
  "epoch": 7,
  "seq": 489213,
  "device_ts": "2026-06-15T14:03:21.118Z",
  "ingest_ts": "2026-06-15T14:03:21.402Z"
}
```

- `sensor_type` ∈ `combustible_gas | co | water_leak | wifi_presence`. For `wifi_presence`, `value` is an anonymous occupancy estimate (count) for the zone and `units` is `"persons_est"` — no device identities are carried. The **`hazard_type`** carried on derived alert/incident records uses exactly the same tokens minus `wifi_presence`, i.e. `combustible_gas | co | water_leak`. The abbreviations `gas`/`CO` are never used on the wire or in guard logic.
- `edge_state` ∈ `normal | warn | alarm` reflects on-device pre-inference; `edge_state:"alarm"` means the node has already fired its local alarm.
- `epoch` is a **per-device boot/counter generation** (incremented on each NVS counter reset/reboot); `seq` is a **monotonic per-device sequence number within an epoch** (restarts at 0 after a reboot). `device_ts` is set by the node; `ingest_ts` is stamped by the Ingestion service.

**Compact LoRa variant.** Over LoRa the JSON is replaced by a fixed-layout CBOR (binary) frame to fit the duty-cycle/payload budget: short integer keys, IDs pre-mapped to 16-bit codes provisioned per building, `sensor_type`/`edge_state`/`units` as enums, `value` quantized, `epoch` and `seq` carried as integers, `device_ts` as a delta from a per-session epoch. The gateway re-expands the CBOR frame back into the canonical `canary.telemetry.v1` JSON before bridging upstream, so downstream services see one schema regardless of transport.

**Out-of-order / duplicate keying.** The idempotency/ordering key is **`(device_id, epoch, seq)`** everywhere in the system, matching the Ingestion store's `UNIQUE` constraint and Redis dedupe. Ingestion treats a reading as a duplicate only if `(device_id, epoch, seq)` already exists, then drops it. Ordering is resolved by `(epoch, seq)` (primary) with `device_ts` as tiebreaker; `ingest_ts` is never used for ordering, only for latency measurement. Because `epoch` is part of the key, a node that reboots and restarts `seq` at 0 produces a *new* `(device_id, epoch, seq)` space and its post-reboot readings are **never** mistaken for pre-reboot duplicates and dropped. A required regression test reboots a node mid-stream and asserts `seq=0..N` post-reboot readings are all accepted, not deduped against the prior epoch.

---

## 6. Core Data Model

> **As built:** every table lives in one database (SQLite by default; hypertables only on Postgres with Timescale), created on startup with no migrations. The hardware adds `nodes` (one row per physical ESP32) and `node_status` (every raw status document); see [`docs/HARDWARE.md`](./docs/HARDWARE.md) §2.

**Store placement.** **PostgreSQL (system-of-record):** `Building`, `Floor`, `Unit`, `Zone`, `Device`, `User`, `Role`, `ResidentUnit`, `Incident`, `IncidentEvent`, `AuditLogEntry`, `Notification`, `EvacuationRoute`, `AssemblyPoint`, `CheckIn`, `ExternalIntegration`. **TimescaleDB (time-series hypertables):** `SensorReading`, `DeviceHealth`, `OccupancyEstimate`. (`Device`/`Sensor` is one entity: a `Device` *is* a sensor node with a `sensor_type`.)

**Text ER.**

- `Building` 1—N `Floor`; `Floor` 1—N `Unit`; `Unit` 1—N `Zone`. (Common-area `Zone`s attach to a `Unit` with `kind=common`.)
- `Zone` 1—N `Device`. Each `Device` has exactly one `sensor_type` and belongs to one `Zone` (and thus a `building/floor/unit/zone` path).
- `Device` 1—N `SensorReading` (TS, keyed by `device_id, epoch, seq`); `Device` 1—N `DeviceHealth` (TS).
- `Zone` 1—N `OccupancyEstimate` (TS, from `wifi_presence` devices) — per-zone anonymous count over time.
- `User` N—M `Role` (RBAC: `resident`, `hoa_manager`, `dispatcher_external`, `system_admin`). `User` N—M `Unit` **through** `ResidentUnit` (a resident may map to multiple units; a unit to multiple residents).
- `Incident` belongs to one `Building` (and may reference a primary `Zone` and a set of affected `Zone`s). `Incident` 1—N `IncidentEvent` (append-only state-transition + observation log). `Incident` 1—N `Notification`. `Incident` 1—N `CheckIn`. `Incident` 1—N `AuditLogEntry` (also any privacy-sensitive identity unlock).
- `CheckIn` references one `User` and one `Incident` (and the `Unit` via `ResidentUnit`).
- `Building` 1—N `EvacuationRoute`; `EvacuationRoute` ends at one `AssemblyPoint`; `Building` 1—N `AssemblyPoint`. `Incident` references the active `EvacuationRoute`(s). The gateway holds a **cached copy** of each `Building`'s `EvacuationRoute`/`AssemblyPoint` geometry so directional signage works with no WAN.
- `ExternalIntegration` belongs to one `Building` (or org) and is the target for `escalation`-state outbound notifications. It carries a `kind` (`arc` for the contracted alarm-receiving center / duty manager, `isu_webhook` for an optional machine-readable ISU feed gated on a signed agreement, `gas_distributor` for ENGIE/Distrigaz Sud) and SLA fields (see §6 key fields / §9); referenced by `Notification` when the channel is external.
- `Notification` references one `Incident` and one recipient (`User` for residents/managers, or `ExternalIntegration` for external).

Key fields (abbreviated): `Incident{ id, building_id, primary_zone_id, hazard_type, severity, state, opened_ts, resolved_ts }`; `IncidentEvent{ id, incident_id, from_state, to_state, reason, actor, payload, ts }`; `OccupancyEstimate{ zone_id, persons_est, confidence, ts }`; `CheckIn{ id, incident_id, user_id, unit_id, status, source, ts }` (`source` ∈ `cloud | gateway_lan`); `AuditLogEntry{ id, incident_id, actor, action, target, identity_unlock(bool), ts }`; `ExternalIntegration{ id, building_id, kind, endpoint, sla_answer_secs, sla_call_to_112_secs, isu_agreement_signed(bool) }`. The `hazard_type` and `severity` fields use the canonical vocabularies defined in §5 and §8 respectively.

---

## 7. Incident State Machine

States (canonical lowercase wire tokens used verbatim across the alert/incident schema, WebSocket topics, FCM data messages, and the Flutter handler): `normal`, `detection`, `verification`, `alarm`, `escalation`, `evacuation`, `resolution`, `false_alarm`. (`normal` is the absence of an open `Incident`; an `Incident` row exists from `detection` onward.) Every transition appends an `IncidentEvent`. An enum-mapping contract test asserts the same token table is honored by all three transports.

| State | Entered when (transition + guard) | Notify targets |
|---|---|---|
| **`normal`** | Default; no active hazard. (Re-entered from `resolution`/`false_alarm` after close.) | none |
| **`detection`** | `normal → detection`: a `SensorReading` or `edge_state` crosses the per-`sensor_type` detection threshold. Guard: value ≥ detection threshold for ≥1 sample. | Internal only (manager dashboard shows "investigating"); no resident alarm yet. |
| **`verification`** | `detection → verification`: corroboration requested. Guard: needs ≥1 of {second sample over threshold, neighboring-zone reading, gateway edge-corroboration flag}. AI triangulation runs here. | Manager dashboard (live). Residents not yet alarmed (avoids false alarms). |
| **`alarm`** | `verification → alarm`: confirmed. Guard: corroborated hazard **OR** `edge_state == "alarm"` from any single node **OR** value ≥ critical threshold (single-sensor critical fast-path skips full verification). **Building-internal alerting is never gated on corroboration:** a single node at its critical threshold raises the building-wide panel by itself. | **Residents (push)** + **managers (web push)** + **gateway local alarm panel (building-wide)**; edge sirens already active. Identity-unlock for accounting authorized + audited. |
| **`escalation`** | `alarm → escalation`: severity/persistence guard met. Guard (uses canonical tokens): `hazard_type ∈ {combustible_gas, co}` at critical level, OR alarm persists > escalation timer, OR unaccounted occupants > 0. Corroboration **is** required here (this is the false-alarm-sensitive outward hop). | **External (primary):** the contracted **ARC / duty manager** (`ExternalIntegration.kind=arc`), obligated to call 112/ISU, plus the relevant gas distributor. **Optional:** machine-readable ISU webhook (`kind=isu_webhook`) only where `isu_agreement_signed`. Managers notified of escalation. |
| **`evacuation`** | `alarm → evacuation` or `escalation → evacuation`: evacuation ordered (auto for critical `combustible_gas`/`co`, or manual by manager/dispatcher). Guard: severity ≥ evacuation threshold OR human order. | **Residents:** `EvacuationRoute`/`AssemblyPoint` guidance + check-in prompt. Managers + external get live accounting. (When WAN is down, the **gateway** drives cached directional signage routing away from the alarming zone and collects check-ins locally.) |
| **`resolution`** | `alarm/escalation/evacuation → resolution`: hazard cleared. Guard: all affected-zone readings back below clear threshold for the clear-hold window AND (for escalated incidents) external/ARC/manager acknowledgement. | Residents "all clear"; managers; external integrations resolved. |
| **`false_alarm`** | `detection/verification/alarm → false_alarm`: not a real hazard. Guard: manager/dispatcher dismissal with reason, OR auto-clear before `alarm` if readings normalize within the verification window. | Residents "stand down" (only if they were alarmed); managers; logged in `AuditLogEntry`. |

Notes: forward-only into `alarm`/`escalation` for safety (no silent regression out of an active alarm except via explicit `resolution`/`false_alarm` with a logged actor). The **edge-local alarm path is independent of this machine** — a node fires locally regardless of which cloud state the `Incident` is in — and the **gateway** independently raises the building-wide panel, drives directional evacuation signage, and runs degraded accounting whenever the cloud is unreachable. **Commissioning requirement:** each high-risk zone (kitchen — `combustible_gas`; boiler — `combustible_gas`/`co`; each bedroom — `co`) must be provisioned with the minimum sensor count needed for corroboration of outward actions to be possible; single-sensor zones still raise the building-wide panel via the single-sensor critical fast-path.

---

## 8. Non-Functional Targets

> **As built:** none of these targets has been measured, and the gateway, cloud and push paths they rely on are not built. In the hub, alerts reach the dashboard and the app over the WebSocket; the edge-local alarm is the firmware's own.

**Detection-to-alert latency budget (target: combustible-gas/CO critical event from physical detection to FCM-accepted ≤ 5 s end-to-end on the WiFi/cloud path; edge-local alarm ≤ 1 s and independent).** The controllable, measurable budget ends at the **FCM hand-off**. Device-side receipt is best-effort and outside the system's control: under Android Doze, OEM background killers (notably Xiaomi/Huawei/Oppo in the RO market), or a hard-killed iOS app, FCM high-priority delivery can take seconds to minutes. The **asserted resident-alerting guarantee is therefore the edge siren + gateway local panel** (the physical alarm), not the phone push.

| Hop | Budget |
|---|---|
| Sensor sample + on-device pre-inference | ≤ 300 ms |
| **Edge-local alarm fire (siren/strobe/valve)** | **≤ 1 s total, cloud-independent (asserted resident-alerting guarantee)** |
| Node → gateway broker (MQTT/WiFi) | ≤ 300 ms |
| Gateway → cloud EMQX (bridge) | ≤ 500 ms |
| Ingestion validate + dedupe + write | ≤ 400 ms |
| Detection + Verification decision | ≤ 1 s (single-sensor critical fast-path skips full verification) |
| Incident open + Notification fan-out to **FCM-accepted** | ≤ 1.5 s |
| **End-to-end physical → FCM-accepted** | **≤ 5 s (device-side receipt best-effort, uncontrollable)** |

ARC escalation SLA (part of the latency/availability budget): contracted ARC answer time and call-to-112 time are tracked as `ExternalIntegration.sla_answer_secs` / `sla_call_to_112_secs`; until a signed ARC contract exists the product cannot claim emergency-services escalation. We instrument what we can actually measure — notification *read* acks feed Accounting — and do not present an unobservable "to-resident" figure. LoRa fallback path relaxes to a best-effort ≤ 30 s FCM-accepted budget (duty-cycle constrained); the edge-local alarm still meets ≤ 1 s.

**Availability targets.** Cloud control/monitoring plane: 99.9% monthly. Ingestion + Detection + Notification (safety path): 99.95%, deployed multi-AZ with no single point of failure. Per-building gateway: designed for autonomous operation so a WAN outage does not disable building-local alarms, directional evacuation, or degraded accounting. Edge nodes: alarm function has no availability dependency on gateway or cloud.

**Fallback behavior summary — what each stage of detection → alert → evacuation → victim-accounting produces in each failure mode.**

| Failure mode | Alert | Evacuation | Victim-accounting | External escalation |
|---|---|---|---|---|
| **(1) WiFi/MQTT down at node** | Node continues local pre-inference + local siren; switches to LoRa for telemetry. Gateway + cloud unaffected for other nodes. | Cloud-driven (normal) for other zones; affected node still self-alarms. | Cloud-driven (normal). | Cloud-driven (normal). |
| **(2) WAN down at gateway** | Gateway raises **building-wide local panel** — single node at critical threshold suffices (single-sensor fast-path); corroboration not required to wake the building. Store-and-forwards telemetry; replays on recovery (deduped via `(device_id, epoch, seq)`). | **Gateway drives cached directional signage** routing occupants *away from the alarming zone* using cached `EvacuationRoute`/`AssemblyPoint`. | **Gateway collects `CheckIn` via LAN/BLE** and computes a **degraded unaccounted count** from its last buffered `OccupancyEstimate` snapshot, shown on the local panel. Cloud re-reconciles on recovery. | Unavailable until WAN returns; ARC/112 cannot be reached automatically — **building-internal life-safety still fully functions.** Operators are advised the building has manual 112-call fallback per ARC procedure. |
| **(3) Cloud detection unreachable (gateway up)** | Edge + gateway alarm paths fire; cloud opens/updates `Incident` on recovery. | Gateway directional signage as in (2). | Gateway degraded accounting as in (2). | Gateway forwards to ARC if it has its own egress path; otherwise as in (2). |
| **(4) FCM/push degraded** | Redundant channels (gateway local panel + edge sirens) alert occupants; web console shows live state for managers. | Cloud or gateway evacuation guidance unaffected. | Read-ack-based accounting degrades to check-ins received by any channel (push, in-app, gateway LAN). | ARC/ISU path unaffected (does not depend on FCM). |

The invariant across all modes: **a real hazard always produces a local audible/visual alarm within ≤ 1 s and a building-wide panel alert, regardless of cloud or gateway state; directed evacuation and a (degraded) unaccounted count survive a full WAN outage on the gateway; and the four-stage path degrades in fidelity, never collapsing to a single stage.**

---

## Backend Architecture

> **As built:** the backend is one FastAPI process on the Pi (`backend/app/`), not the service set described here: an aiomqtt consumer, the ingestion pipeline, detection, the incident service, analysis, notifications (database rows + WebSocket) and the REST/WebSocket API. It needs no EMQX, TimescaleDB or Redis. The notes in the subsections below say what differs.

This section deepens the cloud + per-building backend that sits between the EMQX broker (§2) and the API gateway. It is implemented in Python 3.12 / FastAPI, writes `SensorReading`/`DeviceHealth`/`OccupancyEstimate` to TimescaleDB and the rest of the entities to PostgreSQL 16, and uses Redis 7 Streams as the internal bus — **except on the safety path, where incident-advancing events are persisted to PostgreSQL synchronously before ack** (see §2). Every component obeys the §1 invariant: **nothing here is on the ≤1 s edge-local alarm path** — the cloud is the corroboration, accounting, and escalation brain, not the last line of defense. The corollary, made explicit throughout this section: **when the cloud loses visibility into a node (missed heartbeat, malformed message, gap), the occupant's protection still rests on the edge node's own local alarm**, and the cloud's job in that moment is to make its own blindness *loud* — to managers and, where a node is in or near alarm, to Detection.

### 1. Ingestion

> **As built:** one aiomqtt consumer subscribes to `#` on Mosquitto (QoS 1) and dispatches by topic suffix: no shared subscriptions, no event fast-path, no DLQ and no degraded-zone signal. Hardware messages are size-, depth- and type-checked, and a malformed one is logged and dropped. Duplicates are found by a database lookup on `(device_id, epoch, seq)`, with the unique constraint as backstop; there is no Redis tier. Sensors log in with per-sensor passwords, not certificates. A stale or offline node shows as `attention` in the analysis ([`docs/HARDWARE.md`](./docs/HARDWARE.md) §3) but does not feed detection.

#### Broker integration and consumer topology

The Ingestion service is a horizontally-scalable pool of async workers, each holding a shared MQTT subscription to EMQX. We use EMQX **shared subscriptions** (`$share/ingest/canary/v1/+/+/+/+/+/telemetry`) so EMQX load-balances messages across worker replicas — this gives at-least-once delivery with consumer-group semantics without needing Kafka in front of the broker.

```
EMQX (QoS 1, shared sub)
   └─ $share/ingest/canary/v1/+/+/+/+/+/telemetry   -> Ingestion worker pool (N replicas)
   └─ $share/ingest/canary/v1/+/+/+/+/+/health      -> same pool, health path
   └─ $share/ingest/canary/v1/+/+/+/+/+/event       -> EVENT FAST-PATH (separate, higher-priority sub)
   └─ $share/ingest/canary/v1/+/gateway/status      -> Gateway-health worker
```

Library: `aiomqtt` (asyncio wrapper over paho) for the consumer; QoS 1 everywhere (QoS 2 doubles round-trips and we get idempotency from `(device_id, seq)` ourselves, so QoS 2 buys nothing). The `event` topic gets its **own dedicated subscription and worker** so a flood of routine telemetry can never queue-delay an edge-fired hazard event.

Per-device auth: EMQX uses mutual TLS (X.509 client certs provisioned at manufacturing) plus an ACL rule that pins each `device_id` to publish **only** under its own `canary/v1/{building}/.../{device_id}/#` prefix. This stops a compromised node from spoofing telemetry for another unit — important for a safety system where a fake "all normal" is as dangerous as a fake alarm.

#### Normalization & validation pipeline

Each message passes through a fixed pipeline. The Pydantic model **is** the contract from §5 (`canary.telemetry.v1`), reused verbatim:

```python
class Signal(BaseModel):
    rssi: int; snr: float | None = None
    link: Literal["wifi", "lora"]

class Telemetry(BaseModel):
    schema_: Literal["canary.telemetry.v1"] = Field(alias="schema")
    device_id: str
    sensor_type: Literal["combustible_gas", "co", "water_leak", "wifi_presence"]
    location: Location
    value: float
    units: str
    edge_state: Literal["normal", "warn", "alarm"]
    edge_inference_score: float = Field(ge=0.0, le=1.0)
    signal: Signal
    health: Health
    battery: Battery
    fw_version: str
    seq: int = Field(ge=0)
    device_ts: datetime
    ingest_ts: datetime | None = None   # we stamp this
```

Pipeline stages (each stage emits a metric + can dead-letter):

1. **Decode/parse** — JSON parse; reject non-UTF8 / malformed -> `dlq:ingest:malformed` **and** raise the degraded-zone signal below.
2. **Schema validate** — Pydantic. Validation failures go to `dlq:ingest:schema` with the raw payload (we keep raw bytes for forensic replay) **and** raise the degraded-zone signal below.
3. **Topic↔payload consistency** — assert `device_id`/`location` in payload match the topic segments. Mismatch -> `dlq:ingest:spoof` and an `AuditLogEntry` (this is a tamper signal).
4. **Range/sanity** — per-`sensor_type` physical bounds (e.g. CO ∈ [0, 5000] ppm; `wifi_presence` count ∈ [0, zone_capacity*2]). Out-of-range values are **not dropped** — they are clamped-flagged: written with a `quality_flag` so Detection can decide. Rationale: a sensor reading 40000 ppm is more likely a real failure-to-saturate hazard than a bug; we never discard a possibly-real hazard at ingestion.
5. **Stamp** `ingest_ts = now()` (used only for latency, never ordering — per §5).
6. **Idempotency/order** (below).
7. **Persist + publish** to the internal stream (safety-path events persisted to Postgres synchronously before ack — §2).

#### Malformed / unparseable messages are not a silent drop — they raise a degraded zone (the fix to "quarantine-as-silent-failure")

A DLQ entry is **forensics, not protection**. Nobody is alarmed by a row in `dlq:ingest:malformed`, and a critical gas reading whose JSON got corrupted in transit must not sit in a dead-letter queue while the hazard continues. We treat a parse/schema failure as a *loss of cloud visibility into that node*, and respond on three fronts:

- **The edge node is the backstop, and we make that dependency explicit.** A malformed message means the *cloud* is blind to this node, not that the node is silent: the ESP32-S3 still runs on-device pre-inference and still self-alarms locally (§1 fail-loud, ≤1 s). The malformed-message handling here protects the *cloud-mediated* functions (remote alert, manager view, external escalation) for which the cloud just lost an input; it explicitly relies on the edge-local alarm for in-building occupant protection in the meantime.
- **Raise a degraded/untrusted-zone signal to Detection immediately** — the *same mechanism* used for missed heartbeats and `seq` gaps (§7 "unmonitored zone"). Because the topic is parseable even when the payload is not (the topic carries `building/floor/unit/zone/device`), Ingestion knows *which* zone went dark. If that node (or its zone) is **currently in or near an open `Incident` in `Detection`/`Verification`/`Alarm`**, Ingestion emits a `device.untrusted` event on `stream:events` that Detection treats as a corroborating "this zone may be hazardous and I can no longer see it" signal — it can hold or advance the incident rather than letting a missing reading look like "all normal." For a node with no active incident, it degrades the zone to "untrusted" and surfaces it to managers (not a resident alarm).
- **Alert managers and page on event-topic DLQ growth.** Malformed/schema DLQ entries for **event-topic** messages (edge-fired hazards) page on-call, not just dashboard — and DLQ growth alerting covers event topics, not only the metrics pipeline. A burst of unparseable frames from a building is itself a signal (firmware regression, tampering, or a failing radio link in an area that may be on fire).

```python
async def on_parse_or_schema_failure(raw: bytes, topic: TopicParts, dlq: str):
    await bus.xadd(dlq, {"raw": raw, "topic": topic.raw, "ts": now()})   # forensics
    # protection: treat as loss of visibility, not as nothing-happened
    sev = "near_alarm" if incidents.zone_in_or_near_alarm(topic.zone_id) else "degraded"
    await bus.xadd("stream:events", {
        "type": "device.untrusted", "reason": "unparseable",
        "zone_id": topic.zone_id, "device_id": topic.device_id, "severity": sev,
    })
    await notify.managers_zone_degraded(topic.zone_id, reason="unparseable_telemetry")
    if topic.kind == "event":               # edge-fired hazard frame that failed to parse
        await pager.page_oncall("event-topic DLQ growth", topic)
```

The honesty note (§1): we cannot recover the *content* of a corrupted critical reading from the cloud. What we can do is refuse to let its absence read as safety, lean on the edge node that is still self-alarming, and make a human aware fast.

#### Out-of-order / delayed / duplicate handling (idempotency on `device_id` + `seq`)

The idempotency key is `(device_id, seq)` exactly as §5 defines. We resolve dedupe in two tiers so the hot path stays O(1):

```
Tier 1 (hot, Redis):  per-device "high-water mark" + recent-seq set
Tier 2 (durable):     TimescaleDB UNIQUE (device_id, epoch, seq)
```

```python
# Hot dedupe — Redis. Key carries device epoch (survives reboot, per §5 'epoch').
hw_key   = f"dev:hw:{device_id}"          # last accepted (epoch, seq) as packed int
seen_key = f"dev:seen:{device_id}:{epoch}" # roaring-ish bitfield / sorted-set window

async def accept(device_id, epoch, seq) -> Decision:
    cur = await r.get(hw_key)
    cur_epoch, cur_seq = unpack(cur) if cur else (epoch, -1)

    if epoch > cur_epoch:                  # counter reset after reboot -> new epoch
        await r.set(hw_key, pack(epoch, seq))
        return ACCEPT_NEW_EPOCH
    if (epoch, seq) <= (cur_epoch, cur_seq):
        # could be duplicate OR a delayed older message
        if await r.sismember(seen_key, seq):
            return DUPLICATE                # drop
        return LATE_BUT_NEW                 # accept, mark out-of-order
    return ACCEPT                           # normal forward progress
```

Rules:

- **Ordering** is by `(epoch, seq)` primary, `device_ts` tiebreaker — never `ingest_ts`.
- **Duplicates** (`(device_id, epoch, seq)` already persisted) are dropped at Tier 1; the Tier-2 `UNIQUE` constraint is the backstop (an `ON CONFLICT DO NOTHING` insert) so two workers racing the same redelivered message cannot double-write.
- **Late/out-of-order**: accepted and written, but tagged `late=true`. Detection treats a *late* reading as evidence-for-history but **never reopens a closed incident from a stale low reading** — a delayed "normal" arriving after an alarm must not silence it (forward-only safety, §7).
- **Epoch resets**: the per-device `epoch` in `health` lets a rebooted node restart `seq` at 0 without the system seeing a billion duplicates. On epoch bump we roll the `seen_key` window and emit a `DeviceHealth` reboot record.
- **Gap detection**: if `seq` jumps by > N, Ingestion raises the **same degraded/untrusted-zone signal** described above (`device.gap` -> `stream:events`) so Detection knows it may be blind for that zone — escalated to "near_alarm" severity if the zone has an active incident, exactly as for unparseable messages.

The hot path target is the §8 ≤400 ms ingestion budget; Redis dedupe is sub-millisecond, the TimescaleDB insert is batched (below) so it does not block the decision — except that incident-advancing events are written to Postgres synchronously before ack (§2), which is a single indexed insert and stays within budget.

#### LoRa / mesh fallback ingestion path

LoRa telemetry never reaches the cloud as LoRa. Per §5, the **gateway re-expands the CBOR frame into canonical `canary.telemetry.v1` JSON** and bridges it upstream with `signal.link="lora"`. So Ingestion sees one schema. What differs:

- LoRa frames carry **quantized values** and a **delta-encoded `device_ts`**; the gateway reconstructs absolute timestamps from the per-session epoch before bridging. Ingestion trusts the gateway's reconstruction but records `transport=lora` for downstream confidence weighting.
- LoRa is duty-cycle constrained, so `seq` gaps are expected and frequent. The gap-detection threshold N is per-transport: gaps on `lora` do not raise "blind zone" alarms the way WiFi gaps do.
- Detection applies a **relaxed staleness window** for `lora` readings (the §8 best-effort ≤30 s budget) and lowers confidence on AI triangulation inputs sourced over LoRa, because the lower sample rate degrades the spatial gradient.

#### Trusting / re-verifying edge pre-classification flags

`edge_state` and `edge_inference_score` are **advisory, not authoritative** — the §1 honesty principle applies: the on-device TFLite-Micro model is tiny (quantized, few-KB) and runs on noisy MEMS gas sensors, so it produces false warns (cooking fumes, aerosols, humidity on the gas MOX element) and can miss slow leaks. The cloud treats edge flags like this:

| Edge signal | Cloud behavior |
|---|---|
| `edge_state="alarm"` | **Believed for alerting, re-verified for escalation.** Triggers the §7 `Verification → Alarm` fast-path (a node firing locally is strong evidence) **and opens an `Incident`**. But `Alarm → Escalation` (calling 112/ISU) still requires corroboration: a second sensor, neighboring zone, or sustained raw `value` above critical. We do not auto-dispatch emergency services on one node's edge inference alone. |
| `edge_state="warn"` | **Does NOT open an `Incident`.** Treated as a hint to **raise the zone's sampling/attention** only, because `warn` is explicitly nuisance-prone (cooking, aerosols, humidity on the MOX element); opening a (manager-only) incident on every cooking event would generate constant low-grade noise and risk training residents to ignore alerts (the §G desensitization risk). Detection cross-checks the raw `value` trend; an `Incident` opens only if the raw value then crosses the detection threshold. |
| `edge_inference_score` | Used as one **weighted feature**, never a sole gate. Scores from a `fw_version` known to be a bad model build are down-weighted (we keep a per-firmware reliability table). |
| Disagreement: `edge_state="normal"` but raw `value` crossing threshold | **Cloud wins, raises Detection.** A node that says "normal" while its own raw value is high is itself a fault signal (possible miscalibration or compromised firmware) -> `DeviceHealth` anomaly + audit. |

The re-verification logic lives in the Detection/Verification service, but Ingestion attaches the firmware-reliability weight at write time so it travels with the reading.

**Incident entry guard, reconciled with §7 (the fix to the foundation's inconsistency).** Foundation §7 row Detection said "value ≥ detection threshold for ≥1 sample" while §7 table row #1 and Section B `micro_leak` also opened on `edge_state ∈ {warn, alarm}`. We reconcile these so exactly one rule governs incident creation, building-wide:

> **An `Incident` row is opened only by a threshold crossing (`value ≥ detection_threshold(sensor_type)` for ≥1 sample) OR `edge_state == "alarm"`. `edge_state == "warn"` never opens an `Incident`; it only bumps the zone's sampling rate and attention.**

This requires a one-line correction to the **foundation** to stay consistent: §7 table row #1 (`Normal → Detection`) and §8/Section B references must drop `warn` from the open-incident trigger and read `... OR edge_state == "alarm"` (not `{warn, alarm}`). The Detection-state guard ("value ≥ detection threshold for ≥1 sample") is correct as written; the only change is removing `warn` as an opener. `warn` remains a first-class *attention* signal (raised sampling, surfaced on the manager dashboard as a watched zone) — it just does not create an `Incident` row.

### 2. Service decomposition

All services are FastAPI processes (some are pure consumers with no HTTP surface). The internal bus is **Redis Streams** for best-effort and throughput-tolerant flows — chosen over Kafka because throughput is modest (hundreds of nodes × ~0.1–1 Hz, with bursts), we already run Redis for hot values, and Streams give us consumer groups + per-message ack + replay (`XAUTOCLAIM` for dead consumers) without operating a Kafka/ZooKeeper/KRaft cluster. **But Redis Streams alone is not trusted for the safety path.** Section A's deployment is multi-AZ Kubernetes serving many buildings (the §G 5,000-building target), and Redis-with-AOF-plus-replica is a durability bet the plan itself hedges (§G §3.B: "a Redis failure mid-incident could drop queued detection work"). On `everysec` AOF a Redis crash can lose up to 1 s of acked writes, and during Sentinel failover in-flight hazard events on `stream:events`/`stream:notify` can be lost. That is unacceptable on the alert path. So:

- **Safety-path rule (incident-advancing events).** Any event that may **open or advance an `Incident`** (detection-derived hazard events, `edge_state="alarm"`, `device.untrusted`/`device.gap` near an active incident, state transitions) is **persisted to PostgreSQL synchronously *before* the consumer acks the Redis message** — PostgreSQL is already the §E source of truth for the §7 state machine. Redis Streams remains the fast dispatch fabric, but Postgres is the durable record of "work that must still happen."
- **Reconstruct-from-Postgres after failover.** The Incident Orchestrator and Detection can rebuild their pending work set from PostgreSQL after a Redis failover: a `pending_work` projection (rows for events accepted-but-not-yet-completed) is replayed on startup/recovery, so a lost Redis stream does not mean a lost-and-unprocessed hazard. Redis is then re-seeded from Postgres.
- **AOF policy, restated.** Redis runs `appendfsync always` for the instance backing the safety streams (every write fsync'd, no 1 s window), **and** the Postgres backstop above covers the failover gap regardless. Best-effort streams (`stream:readings`, `stream:occupancy`, analytics) may use a separate Redis instance on `everysec` for throughput — losing a routine telemetry tick is recoverable from the next sample; losing an incident event is not.

If multi-tenant scale later demands it, the producer/consumer interface is abstracted (a `Bus` port) so we can swap Streams for NATS JetStream or Kafka behind the same interface; the Postgres-before-ack safety invariant is independent of which bus implements dispatch.

Internal streams:

```
stream:readings        # all validated SensorReading (Ingestion -> Detection, Analytics)   [best-effort, everysec]
stream:events          # edge events + detection-derived events (Detection -> Incident orch) [SAFETY: Postgres-before-ack]
stream:incident        # incident state transitions (Incident orch -> Notification, Escalation, WS bridge) [SAFETY]
stream:notify          # outbound notification jobs (Incident/Detection -> Notification workers) [SAFETY for critical/emergency]
stream:occupancy       # OccupancyEstimate updates (Ingestion -> Accounting)                  [best-effort, everysec]
dlq:*                  # dead-letter streams per failure class
```

| Service / module | Responsibility | Sync/Async | Consumes / Produces |
|---|---|---|---|
| **Ingestion** | MQTT subscribe, validate, dedupe, persist, fan to bus; raise degraded-zone on parse/gap failures | Async (MQTT in, Streams out) | EMQX -> `stream:readings`, `stream:occupancy`, `stream:events` |
| **Detection/Verification** | Per-`sensor_type` thresholds, cross-sensor gradients, edge-flag re-verification, opens/advances incidents (entry guard per §1) | Async stream consumer | `stream:readings`,`stream:events` -> `stream:events` |
| **Incident Orchestrator** | Owns the §7 state machine, timers/escalation, writes `Incident`/`IncidentEvent`, authorizes identity-unlock, re-mints/relocks `incident_unlock` on lifecycle (§5) | Async + thin sync admin API | `stream:events` -> `stream:incident`,`stream:notify` |
| **AI Triangulation** | Locates likely hazard source from multi-zone gradients; returns confidence + zone ranking | **Async only** (off the verification path); refines and attaches to `IncidentEvent` when ready | consumes `stream:incident`; reads TimescaleDB; writes `IncidentEvent` enrichment |
| **Occupancy/Accounting** | Reconciles `CheckIn` vs `OccupancyEstimate` -> unaccounted count | Async consumer + sync read API | `stream:occupancy`, PostgreSQL `CheckIn` -> incident-scoped projection |
| **Notification** | Fan-out FCM/APNs/SMS/email/webhook, dedupe, retry, receipts | Async worker pool | `stream:notify` -> provider SDKs; writes `Notification` |
| **Escalation/External** | Machine-readable incident push to 112/ISU + gas distributor `ExternalIntegration` | Async, idempotent webhooks | `stream:incident` (state=`Escalation`) |
| **Identity/RBAC** | Auth (JWT), role resolution, gated identity-unlock enforcement, server-side incident-state check on `incident_unlock` (§5) | Sync (request path) | PostgreSQL |
| **Audit** | Append-only `AuditLogEntry` (esp. identity unlocks, relocks, dismissals) | Async, fire-and-forget durable | all services -> PostgreSQL |
| **API/WS gateway** | REST + WebSocket/SSE; bridges `stream:incident` to clients | Sync HTTP + long-lived WS | Redis -> clients |

**Sync vs async boundary rule:** anything on the detection→alert path is async/stream-driven for throughput and replay (with the Postgres-before-ack durability rule above); anything a human operator does (acknowledge, dismiss, order evacuation, unlock identity) is a **synchronous** REST call with an immediate audited result, because operators need confirmation that their safety-critical action took.

**AI Triangulation is off the synchronous verification path entirely (the fix to the 300 ms synchronous RPC).** The plan's own principle is that triangulation "only enriches *where*, never gates *whether*" — so there is no reason to call it synchronously at all, and a 300 ms synchronous HTTP RPC that reads TimescaleDB warm-path (Section B) inside a 1 s verification budget is fragile: under load its own DB reads can exceed 300 ms, and it adds nothing to the Alarm decision. Therefore:

- Verification **never** calls triangulation and **never** waits on it, not even 300 ms. The `Verification → Alarm` decision uses only the corroboration signals in §7 (second sample, neighboring zone, gateway edge-corroboration flag, raw critical value). The full ≤1 s "Detection + Verification decision" budget (§8) is reclaimed for the actual *whether* decision.
- Triangulation runs **asynchronously**: it consumes `stream:incident`, computes the likely source zone ranking from multi-zone gradients (Redis hot window + TimescaleDB warm), and **attaches the result to the `Incident` as an `IncidentEvent` enrichment** (`incident.triangulated`) when ready — pushed to managers/dispatchers over WS as a `by_zone` source estimate the moment it lands. If it is slow or unavailable, the incident proceeds through Alarm/Escalation/Evacuation with no degradation to *whether* or *when*; only the *where* hint arrives later (or not at all), exactly as the plan intends. LoRa-sourced inputs are down-weighted as before.

### 3. Storage usage

> **As built:** SQLite in WAL mode (`synchronous=NORMAL`, `busy_timeout=5000`) on the `backend_data` volume by default, or Postgres via `CANARY_DATABASE_URL`, with hypertables only when Timescale is installed. No continuous aggregates, compression or Redis hot path; detection reads recent readings from the database. An hourly job deletes raw status documents, readings and occupancy estimates older than `CANARY_RETENTION_DAYS` (default 14), 2000 rows per transaction; incidents, events, check-ins and the audit log are kept.

#### TimescaleDB (time-series)

`SensorReading`, `DeviceHealth`, `OccupancyEstimate` are hypertables.

```sql
CREATE TABLE sensor_reading (
  device_id   text        NOT NULL,
  epoch       int         NOT NULL,
  seq         bigint      NOT NULL,
  zone_id     text        NOT NULL,
  sensor_type text        NOT NULL,
  value       double precision,
  units       text,
  edge_state  text,
  edge_score  real,
  fw_weight   real,                       -- firmware reliability weight from ingestion
  quality_flag text,                      -- ok | out_of_range | late
  transport   text,                       -- wifi | lora
  device_ts   timestamptz NOT NULL,
  ingest_ts   timestamptz NOT NULL,
  UNIQUE (device_id, epoch, seq)          -- idempotency backstop (§1)
);
SELECT create_hypertable('sensor_reading','device_ts', chunk_time_interval => INTERVAL '1 day');
CREATE INDEX ON sensor_reading (zone_id, device_ts DESC);
```

**Write path (hot):** Ingestion does **micro-batched** inserts for routine telemetry — accumulate up to 200 rows or 250 ms (whichever first) and `COPY`/multi-row `INSERT ... ON CONFLICT DO NOTHING`. Batching keeps the DB off the critical decision path: detection reads from Redis hot values, not from the DB. Critical/`alarm` readings **and any incident-advancing event** bypass the batch and are written immediately and synchronously before the Redis message is acked (§2) — a hazard reading and the work item it generates must be durable now.

**Read path:**
- **Hot path (sub-second detection):** never hits TimescaleDB. Latest value + rolling window per device live in Redis: `dev:last:{device_id}` (latest reading) and `dev:win:{device_id}` (a capped sorted-set of recent samples for trend/gradient). Detection reads these. AI Triangulation (now async) reads these plus the TimescaleDB warm path off the critical path.
- **Warm path (dashboards, incident timelines, async triangulation):** TimescaleDB direct queries, last 24–72 h from raw chunks.
- **Cold path (history, audits, model training):** continuous aggregates + compressed chunks.

**Continuous aggregates / downsampling:**

```sql
CREATE MATERIALIZED VIEW sensor_1m
WITH (timescaledb.continuous) AS
SELECT zone_id, sensor_type, time_bucket('1 minute', device_ts) AS bucket,
       avg(value) avg_v, max(value) max_v, last(value, device_ts) last_v, count(*) n
FROM sensor_reading GROUP BY zone_id, sensor_type, bucket;
-- + sensor_1h rolled from sensor_1m for long-range charts
```

**Retention & compression:**

| Data | Raw retention | Aggregate retention | Compression |
|---|---|---|---|
| `sensor_reading` (gas/CO/leak) | 30 days raw | 1m: 1 yr, 1h: 5 yr | compress chunks > 7 days |
| `wifi_presence` -> `OccupancyEstimate` | **7 days raw** (privacy: §1 occupancy is anonymous and short-lived) | 1m bucket: 90 days | compress > 2 days |
| `DeviceHealth` | 90 days | 1h: 1 yr | compress > 14 days |
| Incident-linked readings | **never auto-dropped** while incident open + 7 yr after (legal/insurance) | — | — |

WiFi-presence gets the shortest retention deliberately — even anonymized occupancy gradients are sensitive; we keep only what victim-accounting and short-term tuning need.

#### PostgreSQL (system-of-record)

All entities from §6. Notes specific to the backend:

- `Incident` and `IncidentEvent` are written **transactionally** by the Incident Orchestrator: a state transition is `INSERT IncidentEvent + UPDATE Incident.state` in one transaction, so the audit log and current state can never diverge. `IncidentEvent` is append-only (no UPDATE/DELETE grant).
- **PostgreSQL is also the safety-path durability backstop (§2):** incident-advancing events are recorded here (a `pending_work` projection) before the corresponding Redis message is acked, so a Redis failover cannot lose in-flight hazard work — the orchestrator replays `pending_work` on recovery.
- `Notification` rows track delivery lifecycle (§6).
- `AuditLogEntry` writes are append-only and include the `identity_unlock` boolean for every gated occupancy→identity resolution, and an `identity.relock` action when an `incident_unlock` is force-dropped on incident lifecycle transition (§5).
- Reads for the web console are served through cached projections (Redis) for live data and direct PG for config/history.

### 4. Incident state machine in full

> **As built:** the states and forward-only rules are implemented (`backend/app/incidents/`), without timers. An incident closes after `CANARY_CLEAR_HOLD_SAMPLES` (3) consecutive clearing readings from a device that reported the hazard, or when a manager or dispatcher resolves it. `escalation` is passed through only on the automatic critical gas/CO path to `evacuation`. There is no acknowledge step and no `incident_unlock`; dismissing as a false alarm is refused (409) once an incident has reached `escalation` or `evacuation`. One incident per hazard type per building is open at a time.

This is the §7 machine, expanded with timers, guards, and exact notify targets. The Incident Orchestrator owns it. A row exists from `Detection` onward; `Normal` is the no-open-incident state. Forward-only into active-alarm states; the only exits from an active alarm are `Resolution`/`FalseAlarm`, each requiring a logged actor. The **edge-local alarm path is independent of this machine** (§7).

Timers (configurable per building; defaults shown):
- `T_verify` = 30 s (max time in `Verification` before forcing a decision)
- `T_clear_hold` = 120 s (readings must stay below clear threshold this long before `Resolution`)
- `T_escalate` = 90 s (alarm persisting past this auto-escalates)
- `T_checkin` = 60 s (no `CheckIn` response → counted as `no_response` for accounting)

Timers are implemented as Redis sorted-set delay queues (`ZADD incident:timers score=<fire_ts>`) polled by the orchestrator; the authoritative timer set is also recorded with the `Incident` in Postgres (§2 reconstruct-from-Postgres) so a Redis failover does not drop a pending escalation. On transition, obsolete timers are removed so a resolved incident can't fire a stale escalation.

| # | From → To | Trigger / guard | Timers (set/clear) | Notified at this transition |
|---|---|---|---|---|
| 1 | Normal → **Detection** | `SensorReading.value ≥ detection_threshold(sensor_type)` for ≥1 sample **OR `edge_state == "alarm"`** (NOT `warn` — §1 entry guard) | set `T_verify` | Internal only — manager dashboard shows "investigating" (WS `incident.detected`). **No resident alarm.** |
| 2 | Detection → **Verification** | corroboration requested (second sample, neighboring zone, gateway edge-corroboration flag). **Triangulation is NOT invoked here** — it runs async and enriches later (§2). | keep `T_verify` | Manager dashboard live update. Residents **not** alarmed (false-alarm suppression). |
| 3 | Verification → **Alarm** | corroborated: ≥1 of {2nd sample over threshold, neighboring-zone reading, gateway edge-corroboration flag} OR `edge_state=="alarm"` OR `value ≥ critical_threshold` (fast-path, skips full verify) | clear `T_verify`; set `T_escalate`, `T_checkin` | **Residents (FCM/APNs push)** + **managers (web push + WS)** + **gateway local alarm panel cmd**. Identity-unlock authorized + `incident_unlock` minted + `AuditLogEntry(identity_unlock=true)`. Edge sirens already active. |
| 4 | Detection/Verification → **Alarm** (critical fast-path) | `hazard_type ∈ {combustible_gas, co}` AND `value ≥ critical_threshold` | as #3 | as #3, immediately (no waiting on `T_verify`). |
| 5 | Alarm → **Escalation** | `hazard ∈ {gas,co}` at critical, OR alarm persists > `T_escalate`, OR `unaccounted_occupants > 0` | clear `T_escalate` | **External:** 112/ISU + relevant gas distributor via `ExternalIntegration` webhooks (machine-readable incident). Managers notified of escalation (WS `incident.escalated`). |
| 6 | Alarm → **Evacuation** / Escalation → **Evacuation** | `severity ≥ evacuation_threshold` (auto for critical gas/CO) OR explicit manager/dispatcher order | keep `T_checkin` | **Residents:** `EvacuationRoute`/`AssemblyPoint` guidance + "Are you safe?" check-in prompt. Managers + external get **live accounting** (WS `incident.accounting`). |
| — | (async, any active state) | triangulation result ready | — | `incident.triangulated` enrichment attached as `IncidentEvent`; managers/dispatchers get a `by_zone` source-location hint over WS. Never gates a transition. |
| 7 | Alarm/Escalation/Evacuation → **Resolution** | all affected-zone readings < clear_threshold for `T_clear_hold` AND (if escalated) external/manager ack | clear all timers; set 7-yr retention hold on linked readings; **force-drop `incident_unlock` + `AuditLogEntry(identity.relock)`** | Residents "all clear"; managers; external integrations sent `resolved`. |
| 8 | Detection/Verification/Alarm → **FalseAlarm** | manager/dispatcher dismissal **with reason** (audited), OR auto-clear before `Alarm` if readings normalize within `T_verify` | clear all timers; **force-drop `incident_unlock` + `AuditLogEntry(identity.relock)`** (if it was minted) | Residents "stand down" (**only if they were alarmed**, i.e. from `Alarm`); managers; `AuditLogEntry`. |
| 9 | Resolution/FalseAlarm → Normal | close-out complete | — | none (incident archived). |

Guard helpers (illustrative):

```python
def can_escalate(inc: Incident, occ: Accounting) -> bool:
    return ((inc.hazard_type in {"combustible_gas","co"} and inc.value >= CRITICAL[inc.hazard_type])
            or inc.seconds_in_state("Alarm") > T_ESCALATE
            or occ.unaccounted > 0)

def can_resolve(inc: Incident) -> bool:
    below = all(z.last_value < CLEAR[inc.hazard_type] for z in inc.affected_zones)
    held  = inc.seconds_below_clear() >= T_CLEAR_HOLD
    return below and held and (not inc.was_escalated or inc.has_external_or_manager_ack)
```

**Honesty note:** `unaccounted_occupants > 0` as an escalation trigger inherits all the accuracy limits of WiFi-presence sensing (see §6 below). It is surfaced to ISU as an **estimate with confidence**, never as a hard count — overstating certainty here could send responders into a building chasing a phantom occupant or, worse, leave early because the estimate said "all clear."

### 5. REST API surface

> **As built:** the implemented endpoints are listed in [`README.md`](./README.md) ("Key endpoints") and [`docs/HARDWARE.md`](./docs/HARDWARE.md) §4. Auth is a username-only dev token (JWT, 8 h) with role checks only: no refresh, OIDC, building scope or `incident_unlock`. No SSE, no rate limiting. The WebSocket sends `incident`, `checkin` and `node` events, not the topics below.

Base: `/api/v1`. OpenAPI auto-generated by FastAPI for the React and Flutter clients and external connectors.

**Auth:** OAuth2 password/PKCE flow issuing short-lived **JWT access tokens (15 min)** + rotating refresh tokens (HttpOnly cookie for web; secure storage for Flutter). External integrations (112/ISU, gas distributor) use **mTLS + client-credentials JWT** scoped to a single building/org. Tokens carry `sub`, `roles`, `building_ids`, and (when active) an `incident_unlock` claim that grants time-boxed identity access for victim-accounting.

**`incident_unlock` is bound to the Incident lifecycle, not the token (the fix to the 15-min-token vs multi-hour-incident mismatch).** Real gas/CO incidents and evacuations routinely run well past the 15-minute access-token TTL, so binding the unlock to a single access token would either drop a dispatcher's access to the unaccounted-occupant roster mid-evacuation on refresh, or let the unlock silently persist past its scope. Neither is acceptable on the victim-accounting path. Instead:

- **Re-mint on refresh while the Incident is unlock-eligible.** On every token refresh, the Identity service checks the live `Incident` state in PostgreSQL. If the user has a role with accounting access **and** there is an `Incident` for an in-scope building currently in `Alarm`/`Escalation`/`Evacuation`, the new access token is re-minted **with** a fresh `incident_unlock` claim (carrying the `incident_id` and the eligible state). The unlock therefore survives arbitrarily long incidents without ever exceeding 15-minute token rotation.
- **Force-drop on lifecycle exit, regardless of token TTL.** When the `Incident` transitions to `Resolution`/`FalseAlarm` or closes, the Orchestrator drops the unlock (§4 rows #7, #8) and writes `AuditLogEntry(action="identity.relock")`. Because the unlock lives in the Incident lifecycle, it ends when the incident's unlock-eligibility ends — not whenever a 15-minute token happens to expire.
- **Server-side state check ignores stale claims.** Every request to an identity-gated endpoint re-validates the claim against current `Incident` state server-side: an `incident_unlock` whose `incident_id` is no longer in an unlock-eligible state is **ignored** even if the JWT has not yet expired. This closes the window where a still-valid token from just before resolution could otherwise read identities after relock. Each such access (and each denial of a stale claim) writes `AuditLogEntry`.

**RBAC model:** roles from §6 — `resident`, `hoa_manager`, `dispatcher_external`, `system_admin`. Enforced by a FastAPI dependency `require(role, scope)` that checks the role **and** building scope (a manager of building A cannot read building B). Identity-level occupancy data is additionally gated by the live-state `incident_unlock` check above, so even a `dispatcher_external` only sees resident identities while an in-scope incident is actively in `Alarm`/`Escalation`/`Evacuation`, and every access writes `AuditLogEntry`.

Key endpoints by resource:

```
# Incidents
GET    /api/v1/incidents?building_id=&state=        list/filter        hoa_manager, dispatcher_external, system_admin
GET    /api/v1/incidents/{id}                       full detail+timeline  hoa_manager, dispatcher_external
POST   /api/v1/incidents/{id}/acknowledge           ack alarm          hoa_manager, dispatcher_external
POST   /api/v1/incidents/{id}/evacuate              order evacuation   hoa_manager, dispatcher_external   (audited)
POST   /api/v1/incidents/{id}/dismiss               -> FalseAlarm (reason required)  hoa_manager, dispatcher_external (audited)
POST   /api/v1/incidents/{id}/resolve               mark cleared       hoa_manager, dispatcher_external
GET    /api/v1/incidents/{id}/accounting            unaccounted estimate  hoa_manager, dispatcher_external (incident_unlock, live-state checked)

# Check-ins (residents)
POST   /api/v1/incidents/{id}/checkin               {status}           resident
GET    /api/v1/incidents/{id}/checkins              roster             hoa_manager, dispatcher_external (incident_unlock, live-state checked)

# Devices / telemetry (read)
GET    /api/v1/buildings/{bid}/zones/{zid}/devices  device list+health hoa_manager, system_admin
GET    /api/v1/devices/{id}/readings?from=&to=&res= time-series (raw/1m/1h)  hoa_manager, system_admin
POST   /api/v1/devices/{id}/commands                valve/alarm-test (-> canary/.../cmd)  system_admin (audited)

# Config / topology
CRUD   /api/v1/buildings|floors|units|zones         topology mgmt      hoa_manager(rw own), system_admin
CRUD   /api/v1/evacuation-routes|assembly-points    evac config        hoa_manager, system_admin
CRUD   /api/v1/external-integrations                webhook targets    system_admin

# Identity / RBAC
POST   /api/v1/auth/token  /auth/refresh  /auth/logout    (refresh re-mints incident_unlock per live Incident state)
GET    /api/v1/me                                   profile+roles      all authenticated
```

**Real-time channels.** WebSocket for the manager/dispatcher console (bidirectional ack possible), SSE as a fallback for restrictive networks; Flutter uses FCM push for alerts (not WS, to survive backgrounding) plus a WS when foregrounded for the live evacuation/accounting view.

```
WS   /api/v1/ws/incidents?building_id=   (JWT in connect; server bridges stream:incident, scope-filtered)
SSE  /api/v1/sse/incidents/{id}          (same payloads, one-way)

Topics (multiplexed over the WS frame `topic` field):
  incident.detected | incident.verifying | incident.alarm | incident.escalated
  incident.evacuation | incident.accounting | incident.triangulated | incident.resolved | incident.false_alarm
```

Example WS payload (`incident.accounting`):

```json
{
  "topic": "incident.accounting",
  "incident_id": "inc_4471",
  "ts": "2026-06-15T14:05:02Z",
  "building_id": "bld_007",
  "occupancy_est": 23,
  "checked_in_safe": 18,
  "needs_help": 1,
  "no_response": 4,
  "unaccounted_est": 4,
  "confidence": 0.62,
  "by_zone": [
    {"zone_id":"zone_0312_living","occ_est":2,"safe":1,"unaccounted_est":1,"confidence":0.55}
  ],
  "disclaimer": "occupancy is a WiFi-presence estimate, not a verified count"
}
```

Example resident push (FCM data message, actionable):

```json
{
  "type": "evacuation",
  "incident_id": "inc_4471",
  "hazard": "combustible_gas",
  "severity": "critical",
  "title": "GAZ DETECTAT - EVACUATI ACUM",
  "body": "Iesiti pe scara B. Punct de adunare: parcare fata.",
  "route_id": "route_B",
  "assembly_point_id": "ap_front_lot",
  "actions": ["safe_outside","needs_help"],
  "sound": "alarm_critical"
}
```

**Rate limiting:** token-bucket in Redis, keyed by `(sub, route-class)`. Read endpoints generous (e.g. 120 rpm); mutating safety actions (`/evacuate`, `/dismiss`, `/commands`) are **low-limit + idempotency-key required** (5 rpm) to prevent accidental double-orders. Resident `/checkin` is generous (a panicking resident may tap repeatedly — last-write-wins on status, deduped by `(incident_id, user_id)`). Auth endpoints are strictly limited with exponential backoff. External webhook *ingress* (if any acks come back) is mTLS-gated and rate-limited per integration.

### 6. Notification service

> **As built:** the notification service writes `Notification` rows (managers on every transition; residents on alarm, evacuation, all-clear and stand-down; the seeded ARC integration on escalation, evacuation and resolution) and broadcasts the incident on the WebSocket. The rows are a record only: no push, SMS, email or webhook transport is wired in the backend.

A pool of async workers consuming `stream:notify`. Each job is `{incident_id, recipients[], channel_policy, severity, template, dedupe_key}`. For `critical`/`emergency` jobs the originating transition is on the safety path, so the job was persisted to Postgres before its `stream:notify` ack (§2) — a Redis failover cannot lose an emergency notification job.

**Channels & adapters** (one adapter interface, swappable providers):

| Channel | Provider | Used for |
|---|---|---|
| Push (Android/iOS) | **FCM** (Android + iOS via APNs token) / direct **APNs** | resident alerts, evacuation, check-in prompts, all-clear |
| SMS | Twilio / local RO aggregator | fallback when push unacked within 20 s for `critical`; managers without app |
| Email | SES / SMTP | manager summaries, post-incident reports, non-urgent |
| Web push | VAPID + WS | manager/dispatcher console |
| Webhook | signed HTTPS POST (mTLS) | `ExternalIntegration` (112/ISU, gas distributor) — handled by Escalation service which reuses this delivery core |

**Severity levels** map to channel policy and override quiet-hours:

```
info      -> in-app only
warning   -> push (normal priority)
critical  -> push (high priority, bypass DND/quiet hours) + SMS fallback escalation
emergency -> push high-priority + SMS immediately (no wait) + sound=alarm_critical
```

Gas/CO at critical = `emergency`; this is the one case we send push **and** SMS in parallel rather than SMS-as-fallback, because a silenced phone must not delay a life-safety alert.

**Dedupe:** `dedupe_key = sha1(incident_id + recipient_id + transition + channel)`. A `SET NX EX=window` in Redis suppresses duplicate sends for the same transition (e.g. orchestrator retry, or two affected zones in one incident). Different transitions of the same incident are **not** deduped — residents should get distinct "alarm" then "evacuate" then "all-clear" messages.

**Retry:** exponential backoff with jitter (1s, 4s, 16s, cap 60s; max 5 attempts) per channel. Provider errors classified: transient (5xx, rate-limit) → retry; permanent (invalid token) → mark recipient channel dead, **fall over to next channel in policy** (push fails → SMS for critical/emergency). A retry exhausting all channels for an `emergency` recipient raises an internal alert to managers ("resident X unreachable") — relevant to victim-accounting.

**Delivery/receipt tracking:** every attempt writes a `Notification` lifecycle:

```
queued -> sent -> delivered -> read   (+ failed, dead, fellover)
```

- `sent`: provider accepted (FCM message id stored).
- `delivered`: FCM/APNs delivery receipt webhook.
- `read`: client (Flutter/web) calls `POST /api/v1/notifications/{id}/ack` when displayed.
- A `read` for an `emergency` is fed back to Accounting as a weak "device is on and seen" signal (not equal to a `CheckIn`, but better than nothing for the unaccounted estimate).

Honest limit: push delivery receipts are best-effort and laggy; "not delivered" never means "resident not alerted" because the **edge siren + gateway panel** (§7) alerted them physically regardless. Notification tracking informs accounting, it is not the alarm.

### 7. Resilience & deployment topology

> **As built:** one Raspberry Pi running `docker compose`: `mosquitto`, `backend` and `web` (simulators in the `sim` profile), all `restart: unless-stopped`, with bounded json-file logs. No gateway/cloud split, no HA and no observability stack. If the broker goes away the backend reconnects with backoff (up to 30 s) and skips re-delivered retained documents it already has. The sensors' own alarms (buzzer, LED, water valve) never depend on the hub.

The architecture is layered so each layer can lose the one above it and still protect occupants. The §8 invariant holds: **a real hazard always produces a local audible/visual alarm within ≤1 s, regardless of cloud or gateway state.**

#### Behavior under each failure mode

| Failure | What happens | Safety guarantee |
|---|---|---|
| **EMQX broker outage** | Ingestion consumers reconnect with backoff; gateway Mosquitto **store-and-forwards** telemetry (persisted queue) and replays on reconnect. Dedupe on `(device_id, epoch, seq)` makes replay safe — no double incidents. | Edge + gateway alarm paths fire locally; cloud reconciles on recovery. |
| **Malformed / unparseable telemetry from a node** | DLQ for forensics **plus** a degraded/untrusted-zone signal to Detection and a manager alert; if the node is in/near an open incident the signal is treated as "this zone may be hazardous and is now unseen" (§1). Event-topic DLQ growth pages on-call. | Cloud refuses to read silence as safety; the node's own edge alarm still protects occupants in-building. |
| **Network partition (gateway↔cloud / WAN down)** | Gateway runs **autonomously**: local corroboration + raises the **building-wide local alarm panel** on a corroborated hazard, buffers all telemetry. `canary/{building}/gateway/status` shows `wan=down` once reconnected (and is the cloud's signal that this building was in degraded mode). | Building-wide alarm independent of cloud (§2 local alert path). |
| **Node loss** (node dead/offline) | Missing heartbeat (`/health`) + `seq` gap → Detection marks the zone **"unmonitored"** (the same degraded-zone mechanism as malformed messages; surfaced to managers, escalated if near an active incident). Neighboring zones still cover via gradient. | We fail *visible*: managers see the building is partly blind rather than falsely "all normal". |
| **Cloud entirely unreachable** | Edge nodes self-alarm (≤1 s); gateway panel fires building-wide; residents in the building are alerted physically. Remote residents and external escalation are unavailable until recovery. On recovery the cloud opens/back-dates the `Incident` from buffered readings. | Occupants protected; only remote/digital functions degrade. |
| **FCM/push degraded** | Notification falls over to SMS for critical/emergency; gateway panel + edge sirens already alerting in-building; manager console (WS/SSE) shows live state. | Redundant channels per §8. |
| **Redis (bus) failure** | Best-effort streams (`readings`, `occupancy`) resume from last ack on failover; a lost routine tick is recovered from the next sample. **Safety-path events are not trusted to Redis alone:** incident-advancing events were persisted to PostgreSQL before ack (§2), so on Redis failover the Orchestrator and Detection **reconstruct pending work from the Postgres `pending_work` projection** and re-seed Redis. The safety Redis instance also runs `appendfsync always`. | No lost-and-unprocessed hazard: a Redis failover cannot drop an in-flight incident event, because Postgres is the durable record. |
| **PostgreSQL failure** | Multi-AZ primary/standby with automatic failover. Because Postgres is now the synchronous safety-path record, incident-advancing acks block briefly during failover (correctly — better a short pause than a lost hazard); on recovery the orchestrator continues from the durable `pending_work`/`Incident` rows. | State machine durable and reconstructable; the edge + gateway alarm paths are unaffected (they are not PG-gated). |

#### Deployment topology

```
┌─────────────────────────────── PER-BUILDING EDGE GATEWAY (industrial box, on-prem) ───────────────────────────────┐
│  Containers (Docker / k3s lightweight):                                                                            │
│   • mosquitto              (local MQTT broker, persistent store-and-forward queue)                                  │
│   • lora-concentrator      (LoRa RX -> CBOR re-expand -> canonical JSON -> mosquitto)                               │
│   • edge-corroborator      (local cross-sensor logic; drives LOCAL ALARM PANEL via GPIO/relay)                      │
│   • bridge-agent           (MQTT bridge mosquitto -> cloud EMQX over TLS; buffers when WAN down)                    │
│   • local-panel-ui         (optional building-lobby status screen)                                                 │
│  Runs autonomously without WAN. Raises building-wide alarm on corroborated hazard.                                 │
└──────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────┘
                                                │  MQTT/TLS bridge (WAN)
                                                ▼
┌──────────────────────────────────── CENTRAL CLOUD (managed Kubernetes, multi-AZ) ─────────────────────────────────┐
│  Stateless (HPA-scaled, ≥2 replicas each, anti-affinity across AZ):                                                │
│   emqx (clustered)  ·  ingestion  ·  detection  ·  incident-orchestrator  ·  ai-triangulation (async)             │
│   occupancy-accounting  ·  notification  ·  escalation-external  ·  api-ws-gateway  ·  identity-rbac  ·  audit     │
│  Stateful (managed, multi-AZ):                                                                                     │
│   PostgreSQL 16 (primary + standby, auto-failover; safety-path source of truth)                                   │
│   TimescaleDB  ·  Redis 7 (safety instance: AOF always + replica; best-effort instance: everysec)                │
│  Observability: Prometheus + Grafana, OpenTelemetry traces (end-to-end latency SLO), Loki logs                    │
└───────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**What runs where, and why:**
- **Edge gateway = autonomy.** Anything required to alarm a building during a WAN outage lives on the gateway (broker, corroboration, panel driver). This is the deliberate single most important resilience decision: the building's life-safety does not depend on the internet — and it is the explicit backstop when the cloud loses visibility into a node (§1 malformed-message handling).
- **Cloud = corroboration + reach + memory.** Cross-building analytics, async AI triangulation, external escalation, identity/accounting, durable history, and the multi-audience UIs need central state and scale; none of them are on the ≤1 s alarm path.
- **EMQX clustered** (not single node) so broker loss is a degraded reconnect, not an outage; the gateway's store-and-forward covers the reconnect window regardless.
- **Stateless services HPA-scaled with AZ anti-affinity** to hit the §8 99.95% safety-path target with no single point of failure; the Postgres standby plus the Postgres-before-ack safety rule (not Redis durability alone) ensure in-flight hazards survive a pod, AZ, or Redis-failover loss.

---

## AI & Analytics

> **As built:** rule-based versions only, in `backend/app/analytics/` and `backend/app/occupancy/`: triangulation for gas/CO (concentration-weighted centroid + time of first detection, confidence capped at 0.95), occupancy from the air node's radar presence (or the legacy simulator's `wifi_presence`), and false-alarm classification of each sensor's recent readings. No learned models and no Wi-Fi CSI sensing.

This section specifies three analytics modules that sit on the cloud backend (Python 3.12 / FastAPI, per Foundation §4) and consume the `SensorReading`, `OccupancyEstimate`, `DeviceHealth`, and `CheckIn` data. Every module emits a confidence score and a typed verdict that the **Incident Orchestrator** consumes during the `Verification`, `Alarm`, `Escalation`, and `Evacuation` states (§7). All three are designed **explainable-first, learned-later**: rules ship at launch (cold-start), ML upgrades plug into the same interface once labelled data exists. None of these modules can suppress the edge-local alarm path — they only inform cloud-side incident decisions.

A shared output contract keeps the orchestrator decoupled from the method inside each module:

```python
# canary/analytics/contracts.py
from pydantic import BaseModel
from typing import Literal
from datetime import datetime

class AnalyticsVerdict(BaseModel):
    module: Literal["triangulation", "occupancy", "anomaly"]
    incident_id: str | None        # None for steady-state (anomaly/occupancy) outputs
    confidence: float              # 0.0–1.0, calibrated; see per-module degradation rules
    confidence_band: Literal["low", "medium", "high"]  # the ONLY value shown on operator/resident UIs
    method_version: str            # e.g. "rule_v1", "iforest_v2" -> written to IncidentEvent.payload
    payload: dict                  # module-specific (origin estimate, counts, anomaly class)
    ts: datetime
```

The raw `confidence` float is retained only in `IncidentEvent.payload` / the audit record. Every UI (dispatcher, manager, resident) shows the coarse `confidence_band`, never the 2-decimal float — see the over-precision rule in Module 1. Every verdict is written verbatim into `IncidentEvent.payload` (via the orchestrator) so a dispatcher can later see *why* the machine acted, with the `method_version` for auditability.

---

### Module 1 — Hazard-Source Triangulation

**Goal.** From distributed gas/CO concentrations over time, estimate the most probable origin `Zone` (and a ranked list of alternatives) as a **probabilistic hint** that *adds* exclusions to the statically-authored evacuation plan — never as a pinpoint and never as the primary driver of route selection (see "Feed into the state machine").

**Required inputs.**

- For each `combustible_gas`/`co` `Device` in the affected `Building`: the last N minutes of `SensorReading` (`value`, `device_ts`, `seq`) from TimescaleDB, plus the device's static `location` (`floor_id`, `unit_id`, `zone_id`) and 3D coordinates.
- A **building geometry table** (`zone_geometry`): per-`Zone` centroid `(x, y, z)` in metres, adjacency graph (shared walls/doors), and floor index. This is a one-time commissioning artifact — without it, triangulation cannot run and the module returns `confidence = 0`.
- A **coarse airflow prior** (optional): per-building default — stack effect direction (warm air/methane rises; CO follows air currents; LPG/propane pools low), plus HVAC supply/return zones if known. Defaults to "buoyancy only" when unconfigured.
- Sensor health from `DeviceHealth` to exclude faulted nodes.

**Sensor-placement assumptions.** Triangulation quality is bounded by placement, set at commissioning: ≥1 gas/CO node per kitchen and per high-risk zone (boiler room, gas-meter cabinet, basement), plus common-area nodes (stairwell, hallway per floor). We assume nodes are *fixed and surveyed* (coordinates known to ~0.5 m). LPG nodes are mounted low (~30 cm), methane/CO nodes high (~1.8 m), matching gas density — the module must know each node's mounting height because it changes which gas it reliably sees.

**Method — start simple and explainable (rule/geometry tier).** Run three cheap estimators and fuse them; each is individually defensible to a dispatcher.

1. **Time-of-first-detection (TOFD) ordering** — the strongest physical signal. The zone whose node crossed its detection threshold *first* is the prime suspect; propagation order down the adjacency graph corroborates. Resolution is limited by sampling interval and threshold, but ordering survives diffusion better than absolute concentration.

```python
def tofd_rank(readings_by_zone, thresholds):
    # earliest device_ts where value >= zone-detection threshold
    first_cross = {
        z: min((r.device_ts for r in rs if r.value >= thresholds[z]), default=None)
        for z, rs in readings_by_zone.items()
    }
    crossed = {z: t for z, t in first_cross.items() if t is not None}
    return sorted(crossed, key=crossed.get)   # earliest first
```

2. **Concentration-weighted centroid (inverse-distance intuition, run in reverse).** Compute the current concentration centroid; the origin is biased toward the highest-concentration node, corrected by the airflow prior (shift centroid *upwind* of the concentration peak, since gas accumulates downwind/downstream of the source).

```python
import numpy as np
def concentration_centroid(zone_xyz, conc, airflow_vec=None, k=2.0):
    w = np.power(np.clip(conc, 0, None), k)        # emphasise peaks; k tunes sharpness
    if w.sum() == 0: return None, 0.0
    c = (zone_xyz * w[:, None]).sum(0) / w.sum()
    if airflow_vec is not None:
        c = c - airflow_vec * SOURCE_UPWIND_OFFSET_M   # source sits upstream of peak
    spread = np.sqrt((w * ((zone_xyz - c) ** 2).sum(1)).sum() / w.sum())  # weighted std
    return c, spread
```

3. **Gradient ascent over the sensor grid.** Treat node concentrations as samples of a scalar field; step from the centroid toward increasing concentration along the `zone_geometry` adjacency graph until a local max — that node's zone is a candidate origin. Cheap, but only meaningful with ≥3–4 nodes on the affected floor.

**Fusion.** Map each estimate to the nearest `Zone`, then vote: `score(zone) = w_tofd·rank_tofd + w_cent·proximity_to_centroid + w_grad·gradient_hit`, default weights `(0.5, 0.3, 0.2)` (TOFD dominates because it is the most physically robust). Output the top-ranked zone plus the ranked list.

**ML upgrade path.** With logged real/drill incidents (each labelled with true origin), upgrade in two stages: (a) a **Gaussian-plume / advection forward model** — simulate dispersion from each candidate source zone given the airflow prior, compare predicted vs observed per-node concentrations, pick the maximum-likelihood source (a physics-based inverse problem solved by grid search over candidate zones); (b) a learned **GNN** over the `zone_geometry` adjacency graph with node features `[conc, dconc/dt, height, gas_type]` predicting `P(source = zone)`. Both keep the `AnalyticsVerdict` contract; only `method_version` changes.

**Output.** The raw `confidence` float and per-zone `score`s live only in the audit record; UIs render `confidence_band` and a ranked list, never the float.

```json
{
  "module": "triangulation",
  "incident_id": "inc_4471",
  "confidence": 0.46,
  "confidence_band": "low",
  "method_version": "geom_rule_v1",
  "payload": {
    "primary_zone_id": "zone_kitchen_0312",
    "ranked_zones": [
      {"zone_id": "zone_kitchen_0312", "score": 0.71},
      {"zone_id": "zone_hall_flr03",   "score": 0.39}
    ],
    "estimated_xy": [12.4, 7.8], "floor_id": "flr_03",
    "method_agreement": 0.66, "n_sensors_used": 5, "n_sensors_faulted": 1,
    "high_confidence_corroborated": false
  },
  "ts": "2026-06-15T14:03:24.900Z"
}
```

**Confidence computation, banding, and degradation.** Confidence is the *product* of independent quality gates, deliberately conservative:

```
confidence = agreement · density_factor · health_factor · sharpness_factor
  agreement      = fraction of the 3 estimators that agree on the top zone (1.0 if all three)
  density_factor = min(1, n_sensors_used_on_floor / 4)   # sparse grids cap confidence
  health_factor  = n_ok / (n_ok + n_faulted)
  sharpness_factor = clip(peak_conc / mean_conc / SHARP_REF, 0, 1)  # flat field -> low conf
```

Confidence is **hard-capped at 0.6** for the rule tier, and forced to `< 0.3` when only 1–2 nodes report (a single node gives *which zone alarmed*, not triangulation). It degrades automatically as nodes fault, as the concentration field flattens (late-stage saturation), or when estimators disagree.

**Over-precision is a safety hazard — band the confidence on every UI.** A 2-decimal confidence on a physically ill-posed sparse-sensor inverse problem invites dispatchers to read false precision into a coarse hint. The raw float is therefore **never surfaced**; it is bucketed into `confidence_band` and only the band is shown to dispatchers and residents. Because the rule tier is hard-capped at 0.6, the bands are calibrated against that ceiling so the cap is never contradicted on screen:

```
low    : confidence  < 0.30   (or only 1–2 nodes reporting)
medium : 0.30 ≤ confidence < 0.50
high   : confidence ≥ 0.50    (rule tier maxes here, since it is capped at 0.6)
```

`high_confidence_corroborated` is true only when `confidence_band == "high"` **and** the inferred top zone matches the set of actually-alarming sensors' zones (TOFD-observed, not merely inferred). This flag — not the raw float — is what gates any route exclusion in `Evacuation` (see below).

**Realistic accuracy and limitations — brutally honest.** Precise indoor source localisation from sparse fixed point sensors is *physically ill-posed*. Gas does not travel in straight lines from source to sensor: **diffusion** smears the gradient within minutes, **HVAC and stack/buoyancy effects** can carry gas to a sensor far from the source (CO from a basement boiler can alarm a third-floor node first if it rises through a shaft), and **sparse placement** (often 1 node/zone) means the spatial field is undersampled below the Nyquist limit for any real gradient. Realistically this module reliably resolves to the **correct zone or its immediate neighbour** in well-instrumented areas (kitchens, boiler rooms), and only to the **correct floor/wing** elsewhere. It must be presented to dispatchers as a *probabilistic hint with a ranked list and a coarse band*, never a pinpoint. The honest failure mode is a confident-looking wrong zone when a shaft/HVAC path dominates — which is why airflow priors and TOFD (not just peak concentration) are weighted heavily, why confidence is capped and banded, and **why a single inferred source zone is never allowed to redirect an evacuation on its own** (next paragraph).

**Feed into the state machine.** Triangulation runs in **`Verification`** (Foundation §7). Its `payload.primary_zone_id` populates `Incident.primary_zone_id` and the affected-`Zone` set; the verdict (including low confidence) is attached to the `IncidentEvent`. **Triangulation never gates the `Verification → Alarm` transition** — a confirmed hazard alarms regardless of whether we know its origin; localisation is advisory only. The full verdict (raw float + band) is included in the machine-readable incident pushed to 112/ISU during **`Escalation`**.

For **`Evacuation`**, routing **defaults to the statically-authored, HOA-reviewed nearest-safe-exit plan** (`EvacuationRoute`/`AssemblyPoint`, §6). Triangulation does **not** select the route. The route-exclusion rules are, in priority order:

1. **Observed exclusion (always applied):** exclude any route that passes through a zone whose own sensors are *currently alarming* (TOFD-observed). This is based on measured fact, not inference — a route through an actually-alarming zone is excluded regardless of triangulation.
2. **Inferred exclusion (applied only under a high bar):** the triangulated `primary_zone_id` and its adjacency-graph neighbours are added to the exclusion set **only if `high_confidence_corroborated == true`** (band is `high` *and* the inferred zone coincides with an actually-alarming sensor zone). A low/medium-confidence or uncorroborated triangulation is recorded on the `IncidentEvent` but **never alters the route**.
3. If applying exclusions would leave no viable route, the static nearest-safe-exit plan is used unchanged and the manager/dispatcher is alerted to choose manually.

This guarantees that a confidently-wrong triangulation (e.g. CO from a basement boiler first alarming a 3rd-floor node) cannot route residents *away from* a safe exit or *through* the real hazard: only observed alarming zones and high-confidence-corroborated inferences can ever remove a route, and the HOA-authored plan is the floor.

---

### Module 2 — Occupancy & Victim Accounting

**Goal.** Maintain a per-`Zone` and building-wide occupancy estimate during normal operation, and during an `Incident` reconcile it against `CheckIn` records to produce the **unaccounted-occupant list** (present before the incident, not confirmed evacuated) with last-known zone — the single most operationally valuable output for ISU. The cardinal rule: **this module never reports a zone "confirmed empty" from presence data.** Presence is a lower bound on who is inside; only a physical sweep or a per-person safe `CheckIn` clears a unit.

**Required inputs.**

- `OccupancyEstimate` time-series (`zone_id`, `persons_est`, `confidence`, `ts`) derived from `wifi_presence` `Device`s (the ESP32-S3 nodes already emit anonymous per-zone counts per Foundation §5 — no device identities leave the node under normal operation).
- Raw CSI/RSSI presence features at the edge (motion/stationary classification) — used by the node to produce `persons_est`; the cloud sees only the count.
- `ResidentUnit` (known residency: which `User`s map to which `Unit`s, plus the registered headcount per occupied unit) and `Unit→Zone` topology.
- `CheckIn` records (`status` ∈ `safe_outside | safe_inside | needs_help | no_response`) once an incident is open.
- A learned **per-zone occupancy baseline** (time-of-day / day-of-week profile, i.e. the diurnal baseline expectation).

**Baseline learning.** Over a 2–4 week commissioning window, fit a per-zone diurnal baseline of `persons_est` using a robust median-by-(hour, weekday) model with MAD bands (start simple), upgradeable to a STL decomposition or a small per-zone Holt-Winters model. The baseline does two jobs: (1) it sets the *prior* count for zones with weak live signal, and (2) it lets us detect "presence anomaly" (someone in the boiler room at 03:00). Baseline is stored in PostgreSQL and refreshed weekly.

**Count-fusion logic (explainable tier).** Per zone, fuse three evidence sources into a single estimate with a confidence:

```python
def fuse_zone_count(wifi_est, wifi_conf, baseline_est, checkins_inside, incident_active):
    # 1) live WiFi estimate, smoothed (EWMA over last few samples to reject flicker)
    live = ewma(wifi_est)
    # 2) blend with diurnal baseline, weighted by WiFi confidence
    blended = wifi_conf * live + (1 - wifi_conf) * baseline_est
    # 3) during an incident, a known-present check-in is GROUND TRUTH (floor the count)
    floor = checkins_inside if incident_active else 0
    est = max(round(blended), floor)
    conf = wifi_conf if not incident_active else max(wifi_conf, 0.9 if checkins_inside else wifi_conf)
    return est, conf
```

Building-wide count = sum of per-zone estimates, with a sanity clamp against `ResidentUnit` headcount + an expected-visitor margin.

**Victim accounting (the core algorithm) — err on the side of presence.** On `Alarm`/`Evacuation`, snapshot the pre-incident occupancy (the estimate at `Incident.opened_ts` minus a short look-back, to capture who was inside *before* people started fleeing — counts drop fast during evacuation, so we anchor to the pre-event state).

The single most dangerous output this system can produce is a false "all clear". WiFi-presence systematically **undercounts** the most vulnerable (sleeping/motionless, device-less children/elderly — see the limitations below), so the live estimate is *not* a trustworthy ceiling. The algorithm therefore **never lets the unaccounted count floor at the live estimate**. The expected occupancy of a zone is anchored to the **maximum** of (a) the pre-incident WiFi estimate, (b) the diurnal baseline expectation, and (c) the `ResidentUnit`-registered headcount for units that show *any* sign of occupancy — so the count can never fall below known/expected residency:

```python
def expected_occupancy(zone, pre_incident_est, baseline, residentunit_headcount, unit_occupied):
    # The count can NEVER fall below known/expected residency.
    # Undercounting presence sensors must not lower the floor.
    floor_est = residentunit_headcount if unit_occupied else 0
    return max(round(pre_incident_est), round(baseline), floor_est)

def unaccounted(expected_by_zone, checkins, residents_by_unit):
    safe = {c.user_id for c in checkins if c.status in ("safe_outside",)}
    needs_help = {c.user_id: c.last_zone for c in checkins if c.status == "needs_help"}
    # Known residents not yet confirmed safe (named, from roster — see Identity & PII note)
    unconfirmed_known = [
        {"user_id": u, "unit_id": unit, "last_known_zone": last_zone_for(u),
         "status": "unconfirmed"}
        for unit, users in residents_by_unit.items() for u in users
        if u not in safe
    ]
    # Anonymous gap is a LOWER BOUND: expected (anchored, not the raw live estimate)
    # minus those confirmed safe. Anchoring to expected_occupancy means a presence
    # undercount can never drive this to a false 0.
    est_total = sum(expected_by_zone.values())     # anchored expectation, NOT live count
    accounted = len(safe)                          # confirmed evacuated only
    anon_gap = max(0, round(est_total) - accounted)
    return {
        "needs_help": needs_help,                  # highest priority — explicit
        "unconfirmed_known_residents": unconfirmed_known,
        "anonymous_unaccounted_estimate_lower_bound": anon_gap,  # LOWER bound, never a ceiling
        "by_zone_last_known": expected_by_zone,
        # HARD INVARIANT: no zone is ever "confirmed empty" from presence data.
        "zones_confirmed_empty": [
            z for z in expected_by_zone
            if zone_physically_swept(z) or all_residents_checked_in_safe(z)
        ],
    }
```

Three properties are enforced as **hard invariants in code**, not merely prose:

1. **`est_total` is anchored to expected occupancy, never the live estimate.** `expected_occupancy()` takes the `max` of pre-incident WiFi, diurnal baseline, and registered headcount, so a presence undercount cannot lower the floor and cannot drive `anon_gap` to a false 0.
2. **The unaccounted count is a *lower bound*.** It is labelled `anonymous_unaccounted_estimate_lower_bound` everywhere (payload, UI, ISU feed). A reported value of 0 means "no one *known or expected* is unaccounted by this estimate" — it is **not** a statement that the building is empty.
3. **A zone is NEVER reported "confirmed empty" from presence data.** `zones_confirmed_empty` lists only zones that have been *physically swept* or where *every* registered resident has filed a safe `CheckIn`. The presence count alone can never populate this list, so a low/zero estimate can never stand responders down.

This produces three tiers for responders: **explicit `needs_help`** (act first), **named unconfirmed residents** with last-known zone, and an **anonymous gap lower-bound** (likely visitors/children/device-less people the WiFi count may have *missed*, never a count it can prove absent).

**Identity & PII — what is actually unlocked at `Alarm`.** WiFi-presence yields an **anonymous per-zone count** that carries *no identity* (Foundation §1, §5). You therefore cannot "de-anonymize" the presence data — there is nothing to unlock in it. Named accounting comes entirely from a different source: the **`ResidentUnit` roster** (names, units, contact details) plus `CheckIn` records. To be precise, the system distinguishes two clearly separated things:

- **(a) Resident roster / contact PII** — drawn from `ResidentUnit`. This is what powers the *named* unconfirmed list and the check-in nudges. It is ordinary PII, not de-anonymized presence. Access to it is gated to `Alarm`/`Evacuation`, time-boxed, and **every read is audited** with an `AuditLogEntry` (`identity_unlock = true` is reused here strictly to mean "roster PII access for accounting").
- **(b) Per-device / MAC-level presence resolution** — the system **does not do this**. No device identity is stored, so there is no identity-bearing presence feature to retain or reveal. The earlier "de-anonymize presence" framing is dropped: what is unlocked is roster PII (a), and the audit target is roster access, not presence data.

If accounting accuracy ever genuinely required per-device resolution at `Alarm`, that would be a **major privacy change** requiring the (currently absent) retention of identity-bearing presence features at the edge — it is explicitly out of scope here and would have to be designed, documented, and re-reviewed, not slipped in behind imprecise language.

**ML upgrade path.** Replace the EWMA + baseline blend with (a) a calibrated **per-zone count regressor** mapping CSI/RSSI feature vectors → count with a proper uncertainty estimate (quantile regression / conformal prediction for honest intervals — note these give *lower* and upper bounds, and accounting always uses the conservative lower bound for "could anyone still be inside?"), and (b) a **Kalman/particle filter** tracking the building-wide count across zone transitions (people move between zones; a tracker enforces conservation of count and smooths handoffs). Same `AnalyticsVerdict` contract; the empty-zone invariant and the expected-occupancy anchoring remain in force regardless of method.

**Output.** Counts shown to operators carry the lower-bound framing; the `confidence_band` is rendered, not the raw float.

```json
{
  "module": "occupancy",
  "incident_id": "inc_4471",
  "confidence": 0.55,
  "confidence_band": "high",
  "method_version": "fuse_rule_v1",
  "payload": {
    "building_total_est_lower_bound": 23,
    "by_zone": [{"zone_id": "zone_unit_0312", "persons_est_lower_bound": 2, "confidence_band": "high"}],
    "accounting": {
      "confirmed_safe": 14,
      "needs_help": [{"user_id": "usr_88", "last_known_zone": "zone_unit_0507"}],
      "unconfirmed_known_residents": [{"user_id": "usr_91", "unit_id": "unit_0204",
                                       "last_known_zone": "zone_unit_0204"}],
      "anonymous_unaccounted_estimate_lower_bound": 3,
      "zones_confirmed_empty": []
    }
  },
  "ts": "2026-06-15T14:07:10Z"
}
```

**Realistic accuracy and limitations — brutally honest.** WiFi-presence sensing is **device-bound, not person-bound**, and this is the central caveat that must reach every dispatcher UI:

- **It counts devices/RF disturbance, not people.** A resident who left their phone at home reads as "present"; a sleeping person with a quiet, stationary device may read as "absent" (CSI motion features collapse when there is no movement); a device-less child or elderly resident is *invisible*. Two phones on one person inflate the count.
- **Zone resolution is coarse.** RSSI/CSI localises to roughly a room/zone at best, with bleed-through walls — "last-known zone" can be off by one adjacent zone, and floor confusion happens with vertical RF leakage.
- **False negatives are the dangerous direction.** The system can *undercount* exactly the most vulnerable occupants (asleep, no device, infirm). This is precisely why the unaccounted figure is anchored to expected occupancy and treated as a **lower-bound hint, never an authoritative roster**, and why no zone is ever called empty from presence alone. The UI must state "estimate — lower bound — confirm physically."
- **Baseline drift and crowds.** Counting accuracy degrades badly above a handful of people per zone (RF saturation) and after furniture/router changes.

Honest expected accuracy: ±1–2 persons per zone for small counts in a calibrated zone; reliable for *presence/absence trend*, unreliable for *exact headcount*, and **never reliable enough to assert absence**. The design response is conservative confidence, the expected-occupancy floor, and the explicit three-tier accounting above, which never claims a zone is empty with certainty.

**Feed into the state machine.** Occupancy runs continuously in `Normal` (feeding `OccupancyEstimate`). On `Alarm` it snapshots pre-incident occupancy and computes the anchored expectation. The `anonymous_unaccounted_estimate_lower_bound > 0` OR any `needs_help` condition is one of the explicit **guards for `Alarm → Escalation`** (Foundation §7: "unaccounted occupants > 0"); because the estimate is a lower bound anchored to expected occupancy, this guard fails *safe* (it escalates when in doubt). The live accounting payload is surfaced to managers and pushed to 112/ISU in `Escalation`/`Evacuation`. Crucially, the path to `Resolution` for an evacuated building **cannot** be satisfied by a low presence count alone — clearing requires the physical-sweep / all-residents-checked-in conditions that populate `zones_confirmed_empty`. Per Foundation §1, roster-PII access for named accounting is **gated** to `Alarm`/`Evacuation`, time-boxed, and every read writes an `AuditLogEntry` with `identity_unlock = true` (here meaning roster access; no presence data is de-anonymized, because it carries no identity).

---

### Module 3 — False-Alarm Reduction / Anomaly Detection

**Goal.** Cut nuisance alarms (cooking fumes on a gas sensor, aerosol sprays, sensor drift, a single transient spike) without ever suppressing a genuine hazard, and additionally surface **slow micro-leak trends** *before* they breach the detection threshold.

**Required inputs.**

- Streaming `SensorReading` per device (`value`, `device_ts`, `seq`) plus rolling features held in Redis (Foundation §4): EWMA, rate-of-change `dv/dt`, short-window variance, recent peak.
- Cross-sensor context: readings from *other* `sensor_type`s in the same and neighbouring `Zone`s (a real combustion event raises CO *and* often gas/temperature; cooking raises gas but not CO the same way).
- `edge_state` / `edge_inference_score` from the node, and `DeviceHealth` (`self_test`, drift indicators).
- Per-`sensor_type` thresholds (detection, critical, clear) and a learned per-device baseline/noise profile.

**Cold-start strategy — rule-based first (this is the launch behaviour).** No labelled hazard data exists at deployment, so the cold-start path is a deterministic decision tree, and it is intentionally **biased toward false *positives* over false negatives** (a wrongly investigated alarm is acceptable; a missed leak is not):

```python
def classify_event(dev, feats, neighbors):
    # 1) CRITICAL FAST-PATH — never filtered. Goes straight toward Alarm.
    if feats.value >= dev.critical_threshold or dev.edge_state == "alarm":
        return Verdict("genuine", confidence=0.95, reason="critical_threshold")

    # 2) MICRO-LEAK TREND — below threshold but persistently rising.
    if feats.slope_ppm_per_min > SLOW_RISE_MIN and feats.duration_min > SLOW_RISE_WINDOW \
       and feats.value > dev.baseline + SLOW_RISE_DELTA:
        return Verdict("micro_leak_suspected", confidence=0.6, reason="slow_monotonic_rise")

    # 3) LIKELY NUISANCE — fast spike, fast decay, single sensor, no corroboration.
    cooking_like = (feats.slope_ppm_per_min > FAST and feats.decay_fast
                    and not neighbors.co_elevated and dev.sensor_type == "combustible_gas")
    if cooking_like and feats.value < dev.detection_threshold * NUISANCE_MARGIN:
        return Verdict("likely_nuisance", confidence=0.55, reason="transient_no_corroboration")

    # 4) SENSOR DRIFT / FAULT — slow baseline creep + failed self-test + isolated.
    if dev.self_test != "pass" or feats.baseline_drift > DRIFT_LIMIT:
        return Verdict("sensor_fault", confidence=0.5, reason="drift_or_selftest")

    # 5) Threshold crossing with corroboration -> genuine; without -> needs verification.
    if feats.value >= dev.detection_threshold:
        if neighbors.corroborated:
            return Verdict("genuine", confidence=0.8, reason="threshold_plus_neighbor")
        return Verdict("needs_verification", confidence=0.4, reason="single_sensor_threshold")
    return Verdict("normal", confidence=0.9, reason="below_threshold")
```

The two pillars are **multi-sensor corroboration** (a real gas event is rarely solitary; cooking is) and **rate-of-change/decay shape** (nuisances spike-and-decay within minutes; leaks rise and persist).

**ML upgrade path (learned later).** As we accumulate labelled and drill data, layer learned models *behind the same `classify_event` interface*, with rules retained as a safety floor:

- **Unsupervised first (works with no labels):** per-device **Isolation Forest** or robust z-score / EWMA-residual on the multivariate feature vector `[value, dv/dt, variance, neighbor_co, neighbor_gas, temp, time_of_day]` to flag "this pattern is unlike this sensor's normal." Good for drift and novel anomalies; explainable via feature attribution.
- **Supervised once labels exist:** a gradient-boosted classifier (XGBoost/LightGBM) over the same features, output classes `{genuine, cooking, spray, drift, transient}` with calibrated probabilities (Platt/isotonic).
- **Temporal upgrade for micro-leaks:** change-point detection (Bayesian online change-point / CUSUM) on the slow-trend channel to catch monotonic creep earlier and with fewer false trend alarms than a fixed slope threshold.
- **Critical safety invariant across all tiers:** the **critical fast-path (rule 1) is never delegated to an ML model** and never filtered — learned classifiers may only *downgrade* sub-critical, uncorroborated events (suppress nuisances), never *suppress* a critical reading or an `edge_state == "alarm"`.

**Training-data needs.** Supervised models need labelled episodes: cooking/shower-spray sessions (easy to collect deliberately during commissioning — "cook now" labelling campaigns), induced controlled gas releases during drills, and operator dismissal labels harvested from `FalseAlarm` transitions in `IncidentEvent` (every dispatcher dismissal with reason is a free label). Realistically expect months before enough *genuine* hazard samples exist — which is exactly why rules ship first and remain the floor.

**Output.** As with the other modules, UIs render `confidence_band`; the raw float stays in the audit record.

```json
{
  "module": "anomaly",
  "incident_id": null,
  "confidence": 0.6,
  "confidence_band": "medium",
  "method_version": "rule_v1",
  "payload": {
    "device_id": "dev_8f3a21", "zone_id": "zone_kitchen_0312",
    "classification": "micro_leak_suspected",
    "reason": "slow_monotonic_rise",
    "value": 420, "detection_threshold": 1000,
    "slope_ppm_per_min": 11.4, "corroborated": false
  },
  "ts": "2026-06-15T14:03:21Z"
}
```

**Realistic accuracy and limitations — brutally honest.** With rules only (launch), expect to catch obvious cooking/spray transients but still pass through a meaningful nuisance rate, because cooking *can* genuinely produce sustained combustible-gas readings that are physically hard to distinguish from a small leak — the safe resolution is to send ambiguous cases to `Verification` (human + corroboration), not to silently suppress. **The system deliberately accepts higher false-positive cost to keep false negatives near zero.** Micro-leak detection is the most fragile: distinguishing a true slow leak from sensor baseline drift is genuinely hard with low-cost MEMS sensors, so micro-leak verdicts are advisory (managed maintenance alert, not a resident alarm) until corroborated or until they breach threshold. Confidence numbers from the rule tier are heuristic, not calibrated probabilities — which is another reason only the coarse band reaches any UI; only the supervised ML tier yields calibrated confidence, and even then domain shift (new stove, new sensor batch, seasonal HVAC) degrades it, requiring periodic recalibration.

**Feed into the state machine.** This module is the gatekeeper between `Detection` and `Alarm`:

- `classification == "genuine"` or `"critical_threshold"` → satisfies the `Verification → Alarm` guard (corroborated hazard); critical fast-path lets the orchestrator skip full verification (Foundation §7).
- `"needs_verification"` → holds the incident in **`Verification`**, requesting corroboration (second sample, neighbour, gateway edge-corroboration flag) before alarming residents — this is the primary false-alarm dampener.
- `"likely_nuisance"` / `"sensor_fault"` with no corroboration within the verification window → contributes to the **`Detection/Verification → FalseAlarm`** auto-clear (logged in `AuditLogEntry` with reason and `method_version`), and a `sensor_fault` additionally raises a maintenance ticket via `DeviceHealth`.
- `"micro_leak_suspected"` → does **not** alarm residents; it opens a low-severity advisory `Incident` (stays in `Detection`, manager-only dashboard per §7) so the leak is investigated before it ever reaches threshold.

In all cases the verdict and `reason` are written to the `IncidentEvent`, giving managers and ISU a clear, auditable rationale for why residents were or were not alarmed.

---

## Web Dashboard (Frontend)

> **As built:** React 18 + TypeScript + Vite, TanStack Query, and a native WebSocket whose events invalidate queries; hand-rolled SVG floor plan, Recharts, plain CSS; username-only dev login. Views: Manager, Dispatch and Sensors (raw ESP32 data next to the hub's analysis). Served by nginx on the Pi, same origin as the API. See [`web/README.md`](./web/README.md).

The web console serves two of the three audiences in the foundation: **HOA/managers** (`hoa_manager` role) for monitoring, and **utilities/emergency services** (`dispatcher_external` role) for the incident view. Residents are out of scope here (Flutter app). This section deepens the React/TypeScript console that consumes the API Gateway's REST + WebSocket/SSE surface and renders the `Incident` lifecycle from §7.

### Stack

| Concern | Choice | One-line justification |
|---|---|---|
| Framework | React 18 + TypeScript + Vite | Matches foundation §4; Vite gives fast HMR and small prod bundles. |
| Server-state / data fetching | TanStack Query v5 | Matches foundation; dedupes REST reads, caches `Building`/`Incident` history, handles backfill + stale-while-revalidate. |
| Client/real-time state | Zustand | A normalized in-memory store fed by the WebSocket. Chosen over Redux Toolkit because the hot path is a high-frequency stream of `SensorReading`/`IncidentEvent` writes into a flat keyed map — Zustand's transient updates (`setState` without re-render via `subscribe`) let the floor-plan canvas redraw at sensor cadence without re-rendering the React tree. Redux's action/reducer ceremony adds latency and boilerplate on the safety path. |
| Floor-plan rendering | **SVG via `react-konva` (Konva canvas) for the live layer, SVG for static base** | Hybrid: the building/floor base plan is authored as SVG (vector, zoomable, accessible, manager-editable sensor placement). The live per-zone state cells + animated markers render on a Konva **canvas** layer composited on top, because re-tinting dozens of zones at sensor cadence in the SVG DOM causes layout thrash. Canvas redraws are O(pixels), not O(DOM nodes). |
| Charting | Apache ECharts (via `echarts-for-react`) | Handles large time-series (`SensorReading`/`OccupancyEstimate` continuous aggregates) with canvas rendering and built-in downsampling (`large: true`, `sampling: 'lttb'`); Recharts (SVG) chokes past ~2k points. |
| Routing | React Router v6 (data routers) | Role-gated route loaders; loader-level RBAC redirect. |
| Styling / components | Tailwind + Radix UI primitives | Accessible primitives; design tokens drive the hazard color states below. |
| Maps (assembly points) | MapLibre GL | Renders `AssemblyPoint` geolocations for evacuation; open-source, no token. |

**Justification for the SVG+canvas split is load-bearing:** a 10-floor building with ~8 zones/floor and 4 sensor types is ~320 `Device` markers. At a 1 Hz live cadence that is a redraw storm; keeping the live layer on canvas is what lets us hit a smooth UI while the detection→alert path stays ≤5 s (foundation §8).

### Real-time data flow

```
API Gateway (WS /ws/incidents, /ws/buildings/{id}/live)
        │  JSON frames (IncidentEvent, SensorReading delta, OccupancyEstimate, CheckIn)
        ▼
WsClient (single connection per session, native WebSocket + heartbeat)
        │  validates frame against zod schema (mirrors canary.* + IncidentEvent shapes)
        ▼
liveStore (Zustand)  ───────────────►  Konva floor-plan layer (transient subscribe, no React re-render)
  · readings:   Map<device_id, latest>
  · zoneState:  Map<zone_id, {hazardLevel, persons_est}>
  · incidents:  Map<incident_id, Incident + last IncidentEvent>
  · accounting: Map<incident_id, {checkins, unaccounted[]}>
        │  selector hooks (shallow-eq)
        ▼
React components (status panels, lists, summary) re-render only on changed slices
```

**Transport choice — WebSocket, not SSE.** The incident view is bidirectional: dispatchers acknowledge, order evacuation (`Alarm → Evacuation`), and dismiss false alarms, and those round-trip over the same socket for lowest latency. SSE would force a second REST channel for commands. Live telemetry frames are server→client deltas only.

**Backfill + reconnection.** Each frame carries a monotonic `stream_seq` (server-assigned per stream, distinct from the device `seq` in §5). On connect/reconnect the client sends `{"sub": "...", "since_seq": <last_seen>}`; the gateway replays missed `IncidentEvent`s and the latest-per-zone snapshot, then resumes live. Reconnect uses exponential backoff (1s→30s cap, jittered). While disconnected the UI shows a **stale banner** and freezes the "last updated" timestamp per panel — it never silently shows stale data as live, which on a safety console is a correctness requirement. On `Alarm`/`Evacuation` incidents, a dropped socket also triggers a TanStack Query refetch of `GET /incidents/{id}` as a backstop.

```ts
// Frame contract (zod-validated)
type LiveFrame =
  | { kind: 'incident_event'; stream_seq: number; payload: IncidentEvent }
  | { kind: 'reading';        stream_seq: number; payload: { device_id: string; zone_id: string; sensor_type: SensorType; value: number; edge_state: 'normal'|'warn'|'alarm'; device_ts: string } }
  | { kind: 'occupancy';      stream_seq: number; payload: { zone_id: string; persons_est: number; confidence: number; ts: string } }
  | { kind: 'checkin';        stream_seq: number; payload: { incident_id: string; user_id: string; unit_id: string; status: 'safe_outside'|'safe_inside'|'needs_help'|'no_response' } }
  | { kind: 'accounting';     stream_seq: number; payload: { incident_id: string; unaccounted: Array<{ unit_id: string; persons_est: number; last_zone_id: string; last_seen_ts: string }> } };
```

### Hazard visual states

A single source of truth maps `Incident.state` (§7) + per-zone `edge_state`/threshold to four UI levels. Every zone, marker, panel border, and the global app chrome derive their color from this map — color is never hardcoded per component.

```ts
type HazardLevel = 'normal' | 'warning' | 'alarm' | 'evacuation';
// normal:     slate   — no incident / Normal
// warning:    amber   — Detection | Verification, or zone edge_state 'warn'
// alarm:      red      — Alarm | Escalation, or zone edge_state 'alarm'
// evacuation: red+pulse + strobe-safe animation — Evacuation state
```

Accessibility: color is paired with an icon + text label (WCAG; red/amber must not be the only signal). `evacuation` adds a slow pulse, capped well below 3 Hz to avoid photosensitive-seizure risk. A persistent global status bar shows the highest active level building-wide so a manager never misses an escalation while scrolled into a sub-panel.

### Floor-plan visualization

**Layering strategy (bottom→top), composited in one stage:**

1. **Base layer (SVG):** floor outline, units, common areas, stairwells, `EvacuationRoute` polylines, `AssemblyPoint` exits. Authored once, cached.
2. **Sensor-position layer (Konva):** one marker per `Device`, glyph by `sensor_type` (`combustible_gas | co | water_leak | wifi_presence`), tinted by current `edge_state`/`HazardLevel`. Click → device detail (health, `fw_version`, battery, last `seq`).
3. **Per-zone hazard state layer (Konva, alpha-blended):** each `Zone` is rendered as a **discrete state cell** filled with a single color derived from that zone's own actual reading (gas/CO `value` mapped to its `HazardLevel`). This is deliberately **not** a smooth interpolated field: with ~1 sensor/zone, a continuous gradient would imply sub-zone spatial fidelity the sensors do not have (the same over-precision sin avoided for the triangulation marker). Cells carry a hard boundary at the zone edge, the zone's sensor sample point is drawn on top, and the per-cell label shows that zone's reading. See accuracy note.
4. **Triangulated-source marker (Konva, top):** the AI triangulation output rendered as a marker **with an explicit confidence ellipse**, never a bare pin.
5. **Occupancy/accounting overlay (incident view only):** per-zone `persons_est` badges and last-known-zone highlights for unaccounted occupants.

```tsx
<Stage width={w} height={h} scale={zoom}>
  <Layer listening={false}><FloorPlanBaseSvgImage /></Layer>   {/* static */}
  <Layer><ZoneStateCells zones={zoneStates} /></Layer>         {/* discrete per-zone fill, alpha */}
  <Layer><SensorMarkers devices={devices} /></Layer>           {/* interactive sample points */}
  <Layer listening={false}><TriangulatedSource est={src} /></Layer>
  <Layer><OccupancyOverlay zones={occZones} /></Layer>         {/* incident view only */}
</Stage>
```

**Per-zone state cells — accuracy note (must be rendered, not just documented).** Hazard is shown at zone granularity, never finer. Each `Zone` is a discrete cell colored from that zone's own latest reading; the building has roughly one gas/CO sensor per zone, so any value "between" sensors would be pure interpolation and is therefore not drawn. Each cell shows its underlying sensor sample point and that zone's reading, so a dispatcher reads exactly the spatial resolution the sensors provide — no smooth red gradient implying concentration values the system never measured. Where a zone has no live reading (sensor offline/missed heartbeat), the cell renders as an explicit "no data" state rather than being interpolated from neighbors.

**Triangulated source — brutal accuracy note (must be rendered, not just documented).** The triangulation marker is drawn as a **confidence ellipse + a likelihood label** (e.g. "Likely source: kitchen zone, 0.62"), not a precise point. Source localization from a sparse fixed grid of gas/CO sensors is fundamentally under-constrained: gas disperses non-linearly with airflow, HVAC, and door state; with one sensor per zone the spatial resolution can be no finer than a zone. The UI therefore highlights the **most-probable zone(s)**, shows the supporting per-zone readings that produced it, and labels low-confidence results as "unconfirmed — investigate adjacent zones." A confident-looking single pin would dangerously over-state precision to a dispatcher. The marker reads its confidence from the AI triangulation service; if confidence is below threshold it degrades to highlighting all affected `Zone`s rather than one.

**WiFi-presence accuracy note (rendered as uncertainty).** Occupancy badges show `persons_est` as a **range with a confidence chip**, never an exact headcount. CSI/RSSI presence sensing estimates *aggregate motion/occupancy per zone* and cannot reliably count individuals, distinguish residents from devices left at home, or detect a motionless person; sleeping or unconscious occupants are a known blind spot. The unaccounted-occupant list (below) is therefore framed as **"possibly still inside — verify"**, and per the foundation §1/§3 it is reconciled against `CheckIn` records, with identity resolution unlocked only on `Alarm`/`Evacuation` and written to `AuditLogEntry`. The UI never presents presence estimates as a ground-truth roster to responders.

### Role-based views

Routing is role-gated at the loader; both views share the floor-plan component but mount different overlay layers and panels.

**Building manager / HOA view** (`hoa_manager`) — monitoring & maintenance:

- **Building + floor map:** floor switcher, base + sensor layers; warning-level per-zone state cells when an incident is in `Detection`/`Verification`. Read-mostly; can place/relabel `Device`s in a config sub-mode.
- **Live sensor status panel:** grouped by `Floor`→`Zone`, latest `value`/`edge_state` per `Device`, sortable, filter by `sensor_type`.
- **Device health / end-of-life panel:** drives off `DeviceHealth` time-series + `Device.fw_version`/battery. Flags low battery, failed `self_test`, missed-heartbeat (no telemetry within expected window), and **sensor end-of-life** (electrochemical gas/CO cells age out ~2–5 yrs — computed from install date + cumulative exposure). Sorted by urgency.
- **Environmental trends:** ECharts time-series of gas/CO/leak per zone and `OccupancyEstimate` per zone, over continuous-aggregate buckets (hour/day/week).
- **Incident history:** table of past `Incident`s (state, hazard_type, severity, opened/resolved, `FalseAlarm` flag) with drill-in to the full `IncidentEvent` timeline.
- **Maintenance recommendations:** derived feed — "replace CO cell in unit_0312 (EOL in 30d)", "node dev_8f3a21 missed 40% of heartbeats — check WiFi/LoRa." Actionable, not just status.

**Utility / emergency-services incident view** (`dispatcher_external`) — single live incident, optimized for dispatch:

- **One-glance situational summary** (top, always visible): building address, `hazard_type`, `severity`, current `Incident.state`, time-in-state, # floors affected, unaccounted count, evacuation %. Designed to be read in <5 seconds.
- **Triangulated hazard source on floor plan:** confidence-ellipse marker + affected-zone highlight + supporting per-zone readings (per accuracy note).
- **Live occupancy + unaccounted-occupant list:** per `Unit`, with `last_known_zone_id`, `last_seen_ts`, and `CheckIn` status. Sorted: `needs_help` → `no_response`/unaccounted → `safe_inside` → `safe_outside`. Each entry labeled "possibly inside — verify."
- **Evacuation progress:** % checked-in-safe vs estimated occupancy, per-floor breakdown, `EvacuationRoute`/`AssemblyPoint` status on the map.
- **Action bar:** acknowledge incident, order evacuation (`Alarm → Evacuation`), mark `FalseAlarm` (with reason → `AuditLogEntry`) — all gated to `dispatcher_external`/`hoa_manager` and round-tripped over the WebSocket.

### Component tree — emergency-services incident view

```
<IncidentViewRoute>                         // RBAC loader: requires dispatcher_external | hoa_manager
 └─ <IncidentProvider incidentId>           // subscribes liveStore slice + TanStack Query(GET /incidents/:id)
    ├─ <StaleBanner />                       // shown when WS disconnected
    ├─ <SituationalSummaryBar>               // one-glance dispatch header
    │   ├─ <HazardStateBadge state hazardType severity />
    │   ├─ <TimeInState /> <FloorsAffected /> <EvacProgressMini />
    │   └─ <UnaccountedCountChip />
    ├─ <IncidentWorkspace>                   // 2-pane: map left, panels right
    │   ├─ <FloorPlanStage>                  // SVG base + Konva live layers
    │   │   ├─ <FloorSwitcher />
    │   │   ├─ <BaseLayerSvg />              // outline, routes, assembly points
    │   │   ├─ <ZoneStateCellLayer />        // discrete per-zone fill + sample points
    │   │   ├─ <SensorMarkerLayer onSelect />
    │   │   ├─ <TriangulatedSourceLayer />   // confidence ellipse + label
    │   │   └─ <OccupancyOverlayLayer />     // persons_est badges, last-known-zone
    │   └─ <IncidentSidePanels>
    │       ├─ <UnaccountedOccupantList />   // sorted needs_help → no_response → safe
    │       ├─ <EvacuationProgressPanel />   // per-floor %, route/assembly status
    │       ├─ <CheckInFeed />               // live CheckIn frames
    │       └─ <IncidentTimeline />          // append-only IncidentEvent log
    ├─ <DispatchActionBar>                   // WS round-trip, RBAC-gated
    │   ├─ <AcknowledgeButton />
    │   ├─ <OrderEvacuationButton />         // Alarm → Evacuation
    │   └─ <MarkFalseAlarmDialog />          // reason -> AuditLogEntry
    └─ <DeviceDetailDrawer />                // opens on marker select
```

### Logging / audit search view

Backed by `AuditLogEntry` and `IncidentEvent` (foundation §6). Server-side paginated/filtered (volume + tamper-evidence — the client must not hold the full audit set).

- **Filters:** date range, `building_id`, `incident_id`, `actor` (user/system), `action`, `target`, and a dedicated **`identity_unlock = true`** toggle (the privacy-sensitive victim-accounting unlocks from §1). 
- **Columns:** `ts`, actor, action, target, `incident_id` (linked), `identity_unlock` badge.
- **Export:** CSV/PDF for handover to ISU/authorities, itself logged as an `AuditLogEntry`.

```
GET /api/v1/audit?building_id=&incident_id=&actor=&action=&identity_unlock=&from=&to=&cursor=&limit=
GET /api/v1/incidents/{incident_id}/events?cursor=&limit=     // IncidentEvent timeline
```

### Auth / RBAC / session handling

- **AuthN:** OIDC (Authorization Code + PKCE) against the Identity/RBAC service. Short-lived access JWT (~15 min) + httpOnly, `Secure`, `SameSite=Strict` refresh cookie — the access token is held in memory only (never `localStorage`) to limit XSS token theft on a safety console. Silent refresh on a timer; refresh failure → forced re-auth.
- **AuthZ / RBAC:** roles from §6 — `hoa_manager`, `dispatcher_external`, `system_admin` (residents do not use the web console). Enforced in three places: (1) **route loaders** redirect unauthorized roles; (2) **component-level** gates hide actions (e.g. `OrderEvacuationButton`); (3) the **server re-checks every call** — client gating is UX only, never the security boundary. `dispatcher_external` is **scoped to a single `Incident`**, matching §E's one-incident token binding: the grant is bound to the specific `incident_id` the dispatcher is handling and expires with that incident, so a dispatcher can see only that one escalated incident's building data and resident roster — never every escalated building's roster at once. A dispatcher genuinely handling multiple concurrent incidents is minted one incident-scoped grant each, each separately audited.
- **Identity-unlock UX:** when a `dispatcher_external`/`hoa_manager` opens the unaccounted-occupant list during `Alarm`/`Evacuation`, the resident-identity reveal is an explicit, time-boxed, audited action surfaced in-UI ("Identity access logged — expires with incident"), matching the §1 privacy gate and writing `AuditLogEntry{ identity_unlock: true }`. The reveal is bound to the same single `incident_id` as the dispatcher's grant, so identity access can never span incidents.
- **Session safety:** idle-timeout with a warning modal; but if the active building has an incident in `Alarm`/`Escalation`/`Evacuation`, idle-logout is suspended so a dispatcher's console never blanks mid-incident. WebSocket auth uses the same access token, re-sent on each (re)connect; expiry mid-stream triggers silent refresh + resubscribe with `since_seq` so no frames are lost.

---

## Mobile App

> **As built:** Flutter + Riverpod talking to the Pi over REST + WebSocket on the LAN: full-screen alarm, evacuation guidance, check-in with an offline queue, and the hub's sensor analysis without raw values ("Home status"; "Building sensors" on the manager screen). Sign-in by username (no invite codes). FCM is optional and off by default; there is no gateway LAN/BLE path and no foreground service. See [`mobile/README.md`](./mobile/README.md).

The resident app is the last meter of the safety path: when the backend transitions an `Incident` to `Alarm`/`Evacuation`, this app is what wakes a sleeping resident at 03:00, routes them away from the hazard, and feeds their `CheckIn` back into victim-accounting. It is built in **Flutter (Dart)**.

### Why Flutter for a life-safety app

- **Single codebase, identical alert logic on both platforms.** A divergent iOS/Android alert path is a safety liability: the severity-to-channel mapping, the evacuation state machine, and the check-in flow must behave identically. One Dart codebase removes an entire class of "it alarmed on Android but not iOS" bugs. Platform divergence is confined to thin platform-channel shims (critical-alert entitlement, full-screen intent).
- **AOT native compilation → fast cold-render of the alert UI.** Flutter compiles to native ARM; the full-screen alarm screen renders without a JS bridge round-trip. On a notification cold-start (terminated app), the Skia/Impeller renderer paints the first alarm frame in tens of ms, which matters when the app is launched *by* the FCM message into the ≤5 s end-to-end budget (Foundation §8).
- **Mature notification + background plugin ecosystem.** `firebase_messaging`, `flutter_local_notifications`, and `flutter_foreground_task` are the de-facto stack and expose the exact low-level controls (Android notification channels, full-screen intents, `AndroidServiceType`) this use case needs. The one gap — the iOS critical-alert interruption level — is closeable with ~30 lines of platform-channel Swift (below).

Trade-off acknowledged: Flutter cannot, on its own, reach the iOS critical-alert interruption level or set an Android full-screen intent — both require a native shim. We treat those shims as first-class, not as escape hatches.

### State management: Riverpod

Chosen over Bloc. The alert/incident state is **global, push-driven, and read from many places** (alarm overlay, status view, foreground-service isolate, check-in sheet). Riverpod's `StreamProvider`/`NotifierProvider` model fits a single source of truth fed by an FCM/WebSocket stream, gives compile-safe DI (the `IncidentRepository`, `CheckInQueue`, and `Connectivity` are all overridable providers — critical for widget-testing the alarm path without a live backend), and avoids Bloc's event/state boilerplate for what is fundamentally "observe one incident, mutate my check-in." `ProviderContainer` can also be constructed in the foreground-service isolate (which has no widget tree) to reuse the same repositories.

```dart
// The app's safety-critical source of truth. Fed by FCM data messages + WebSocket.
final activeIncidentProvider =
    NotifierProvider<ActiveIncidentNotifier, IncidentState?>(ActiveIncidentNotifier.new);

// Drives whether the full-screen alarm UI is mounted.
final alarmGateProvider = Provider<bool>((ref) {
  final inc = ref.watch(activeIncidentProvider);
  return inc != null && inc.state.indexAtLeast(IncidentStateEnum.alarm);
});
```

### Onboarding and unit/building linking

Linking a `User` to one or more `Unit`s (via `ResidentUnit`, Foundation §6) must be authoritative — an evacuation order and the "are you safe?" prompt are scoped per building/unit. Self-service alone is unsafe (a malicious actor could see a neighbour's incidents), so we use **HOA-issued invite codes** with a fallback to manager approval.

Flow:
1. Phone-number auth (Firebase Auth, `phone` provider — Romanian residents reliably have SMS; email is optional). Justification: ties identity to a real, reachable channel for the check-in nudge — and, critically, gives us a verified phone number for the parallel SMS life-safety channel (below).
2. Enter an **invite code** issued by the `hoa_manager` for a specific `Unit` (or scan a QR encoding `building_id`+`unit_id`+signed token). Backend validates and creates the `ResidentUnit` row, role `resident`.
3. Manager-approval fallback: if no code, the resident requests linking and the `hoa_manager` approves in the web console; until approved the user is in a `pending` state and receives no incident pushes.
4. **Immediately register the FCM token** post-link so the device is alertable before the user even finishes the tour:

```dart
Future<void> registerDevice(String userId) async {
  // iOS: APNs token must exist before any FCM API call (verified FlutterFire requirement).
  if (Platform.isIOS) {
    String? apns;
    for (var i = 0; i < 10 && apns == null; i++) {
      apns = await FirebaseMessaging.instance.getAPNSToken();
      if (apns == null) await Future.delayed(const Duration(milliseconds: 500));
    }
  }
  final token = await FirebaseMessaging.instance.getToken();
  await api.putDeviceToken(userId: userId, fcmToken: token, platform: Platform.operatingSystem);
  FirebaseMessaging.instance.onTokenRefresh.listen(
    (t) => api.putDeviceToken(userId: userId, fcmToken: t, platform: Platform.operatingSystem),
  );
}
```

The Notification service stores `(user_id, fcm_token, platform)` and fans out per affected `Unit` on `Alarm`/`Evacuation`.

### FCM/APNs alert payload schema and severity

The backend Notification service sends a **data-only FCM message** (not `notification`) for safety alerts. Reason: a `notification`-key message is rendered by the OS and the app gets **no code execution** when backgrounded/terminated — it cannot escalate to a full-screen intent, start the foreground service, or pick the critical interruption level. Data-only messages invoke our background handler on both platforms, and *we* construct the local notification with the right channel/intent. (For iOS critical alerts we additionally set the APNs `interruption-level` via FCM `apns.payload.aps`.)

```jsonc
// FCM message constructed by the Notification service. Mirrors Incident fields (Foundation §6/§7).
{
  "message": {
    "token": "<device_fcm_token>",
    "data": {                                  // data-only -> our handler always runs
      "schema": "canary.alert.v1",
      "incident_id": "inc_3f21",
      "building_id": "bld_007",
      "primary_zone_id": "zone_kitchen",
      "affected_zone_ids": "zone_kitchen,zone_hall_03",
      "hazard_type": "combustible_gas",        // combustible_gas|co|water_leak
      "incident_state": "evacuation",          // Foundation §7 state names verbatim
      "severity": "critical",                  // info|warning|critical|life_safety
      "triangulated_source_zone_id": "zone_kitchen",
      "triangulation_confidence": "0.62",      // surfaced honestly in UI; see limits below
      "evacuation_route_id": "route_03_east",
      "assembly_point_id": "ap_courtyard",
      "checkin_required": "true",
      "issued_ts": "2026-06-15T14:03:23.9Z",
      "ttl_action": "alarm"                     // alarm | standdown | allclear | checkin_nudge
    },
    "android": {
      "priority": "high",
      "ttl": "120s"                             // short TTL: a stale gas alert is worse than none
    },
    "apns": {
      "headers": { "apns-priority": "10", "apns-push-type": "alert" },
      "payload": {
        "aps": {
          "alert": { "title": "GAS DETECTED — Evacuate", "body": "Kitchen, Floor 3. Use East stairwell." },
          "sound": { "critical": 1, "name": "alarm.caf", "volume": 1.0 },  // critical-alert sound
          "interruption-level": "critical"      // requires the entitlement (below)
        }
      }
    }
  }
}
```

**Severity → behaviour mapping** (drives channel selection and whether we break through DND):

| `severity` | Trigger (Foundation §7) | Android channel / behaviour | iOS interruption level |
|---|---|---|---|
| `info` | `Detection` (manager-visible only) | not sent to residents | — |
| `warning` | `Verification` | (not sent to residents — avoids false alarms) | — |
| `critical` | `Alarm`, hazard ∈ {gas, CO} | `alarm_critical` channel, `IMPORTANCE_MAX`, full-screen intent, loops alarm sound | `timeSensitive` (breaks scheduled-summary, not Focus) |
| `life_safety` | `Evacuation`, critical gas/CO | `alarm_critical`, full-screen intent, **+ foreground service**, bypass-DND via critical entitlement | `critical` (breaks silent switch + Focus/DND) |

### Background handler, channels, and full-screen intent

The background handler runs in a separate isolate; it must initialise its own plugin instances and a `ProviderContainer` for the queue. We register Android channels at app start (channels are immutable once created — importance must be set correctly the first time).

```dart
@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage m) async {
  await Firebase.initializeApp();
  final data = m.data;
  if (data['schema'] != 'canary.alert.v1') return;

  switch (data['ttl_action']) {
    case 'alarm':
      await _showAlarmNotification(data);             // full-screen intent
      if (data['incident_state'] == 'evacuation') {
        await _startIncidentForegroundService(data['incident_id']!);
      }
      break;
    case 'standdown':                                  // -> FalseAlarm
    case 'allclear':                                   // -> Resolution
      await flnp.cancel(_kAlarmNotifId);
      await FlutterForegroundTask.stopService();
      await _showInfoNotification(data);
      break;
    case 'checkin_nudge':
      await _showCheckInNotification(data);
      break;
  }
}

const _alarmCriticalChannel = AndroidNotificationChannel(
  'alarm_critical', 'Hazard alarms',
  description: 'Gas / CO / fire evacuation alarms. Cannot be silenced.',
  importance: Importance.max,                 // heads-up + full-screen eligible
  playSound: true,
  sound: RawResourceAndroidNotificationSound('alarm'),
  enableVibration: true,
  audioAttributesUsage: AudioAttributesUsage.alarm, // routes via ALARM stream -> louder under DND
);

Future<void> _showAlarmNotification(Map<String, String> d) async {
  final android = AndroidNotificationDetails(
    'alarm_critical', 'Hazard alarms',
    importance: Importance.max, priority: Priority.max,
    category: AndroidNotificationCategory.alarm,
    fullScreenIntent: true,                    // launches AlarmActivity over lockscreen
    ongoing: true, autoCancel: false,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    actions: const [
      AndroidNotificationAction('safe', "I'm safe"),
      AndroidNotificationAction('help', 'I need help'),
    ],
  );
  const ios = DarwinNotificationDetails(
    interruptionLevel: InterruptionLevel.critical, // flutter_local_notifications exposes this
    sound: 'alarm.caf', presentSound: true,
  );
  await flnp.show(_kAlarmNotifId, _title(d), _body(d),
      NotificationDetails(android: android, iOS: ios), payload: jsonEncode(d));
}
```

`fullScreenIntent: true` requires the `USE_FULL_SCREEN_INTENT` permission. On **Android 14+ this permission is no longer auto-granted** for general apps; it is auto-granted only to apps whose core function is alarms/calls. We declare it and, at first launch, route the user to `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` via a platform channel to confirm it (and gracefully degrade to a max-importance heads-up + alarm sound if denied).

### iOS critical-alert entitlement (platform channel)

`firebase_messaging`/`flutter_local_notifications` can *render* a critical alert, but **requesting the critical-alert authorization** at runtime needs `UNAuthorizationOptions.criticalAlert`, which is beyond the default permission request. We add a thin platform channel:

```swift
// AppDelegate.swift — MethodChannel "canary/critical_alerts"
let ch = FlutterMethodChannel(name: "canary/critical_alerts",
                              binaryMessenger: controller.binaryMessenger)
ch.setMethodCallHandler { call, result in
  if call.method == "requestCriticalAuth" {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge, .criticalAlert]) { granted, _ in
        result(granted)   // false if user/OS declined critical alerts
    }
  } else { result(FlutterMethodNotImplemented) }
}
```

```dart
const _criticalCh = MethodChannel('canary/critical_alerts');
Future<bool> requestIosCriticalAuth() async =>
    Platform.isIOS ? (await _criticalCh.invokeMethod<bool>('requestCriticalAuth') ?? false) : true;
```

**Honest constraint:** the critical-alert entitlement (`com.apple.developer.usernotifications.critical-alerts`) is **not self-serve** — it requires a special request to Apple justifying a genuine health/safety/security use case, and approval is discretionary and can take weeks. A life-safety building-alarm app is squarely in the intended category, but the plan must treat approval as a dependency with a fallback: until granted, we ship with `timeSensitive` interruption level on iOS.

**Critical limitation — `timeSensitive` does not cover remote residents.** `timeSensitive` breaks through a scheduled-summary and survives *most* Focus modes, but it does **not** break through the physical mute switch or a fully-engaged Focus/DND, and it cannot raise volume on a silenced phone. For a resident who is **inside the building**, this gap is covered by the redundant in-building alarm paths — the gateway local panel and edge sirens (Foundation §8) reach them regardless of phone state. But those paths are **in-building only.** A resident who is **outside the building** — and the foundation explicitly serves remote residents — with a silenced or DND'd iPhone gets *neither* the in-building siren *nor* a breaking-through push until the critical-alert entitlement is granted. **This is not covered by redundancy; redundancy is in-building only.**

This matters directly for victim-accounting: a remote resident who is in fact safe-outside but unreachable never check-ins, so Accounting counts them as `no_response` and inflates the **unaccounted-occupant** figure that first responders act on (Foundation §3) — the opposite of the accuracy this whole path exists to provide.

**Decision — parallel SMS for remote residents.** We therefore do **not** rely on push alone for remote residents on iOS. On every `Alarm`/`Evacuation`, the Notification service sends life-safety SMS **in parallel** (not as a fallback after a 20 s push-ack timeout) to the verified phone number of every affected resident the system believes is **outside the building** (no recent in-building `OccupancyEstimate`/presence signal for their `Unit`). This matches the gas/CO emergency parallel-SMS rule already established in Foundation §A6 — SMS goes out alongside push, immediately, because a delayed life-safety alert is a failed one. The SMS carries the hazard, the assembly point, and a deep link into the check-in flow. We never let a single channel be the only thing between a resident and a gas alarm: edge sirens + gateway panel cover in-building residents, and parallel SMS covers remote residents whose iPhone may be silenced.

Until the entitlement is granted we accept this posture explicitly: **on iOS, remote residents are reliably reached by SMS, not by push** — the critical-alert push, when approved, simply adds a second breaking-through channel rather than being the only one.

### Foreground service during an active incident

Once an `Incident` reaches `Evacuation` we start a foreground service (`flutter_foreground_task`) so the app keeps a live WebSocket to the incident stream, keeps re-arming the alarm if dismissed, and can queue/flush check-ins — none of which survive on background execution limits alone.

```dart
Future<void> _startIncidentForegroundService(String incidentId) async {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'incident_service', channelName: 'Active incident',
      channelImportance: NotificationChannelImportance.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000), // re-check incident state every 5s
      autoRunOnBoot: true, allowWakeLock: true, allowWifiLock: true,
    ),
  );
  await FlutterForegroundTask.startService(
    serviceTypes: const [ForegroundServiceTypes.dataSync, ForegroundServiceTypes.location],
    notificationTitle: 'Evacuation in progress',
    notificationText: 'Follow guidance to the assembly point.',
    callback: incidentServiceCallback, // top-level @pragma('vm:entry-point')
  );
}
```

The `location` service type is declared only because evacuation guidance *may* use positioning; it is started only with consent (below). The service holds a WiFi + wake lock so the alert socket stays alive on a locked device.

### Background reliability and platform constraints (concrete)

- **Android Doze / battery optimization:** Doze defers normal jobs, but **`apns-priority`/FCM `high` priority data messages are delivered with a high-priority FCM allowance** and our background handler runs. To keep the foreground service alive across aggressive OEM killers (Xiaomi/Huawei/Oppo are the worst in Romania's Android market), we (1) request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` during onboarding via `FlutterForegroundTask.requestIgnoreBatteryOptimization()` and `isIgnoringBatteryOptimizations`, and (2) surface a one-time "allow auto-start" deep link for known OEMs. We document that on a hard-killed app, FCM high-priority delivery is the guarantee, not the foreground service.
- **iOS background execution:** there is no long-running background service on iOS. A terminated iOS app cannot keep a socket. We rely on the **critical/time-sensitive push** to wake the app into `_bgHandler`, render the alarm, and (if the user taps) bring it foreground where the foreground task and socket resume. This asymmetry is by design and is why the push payload is self-contained (it carries route/assembly IDs so the alarm is actionable with zero network). For a silenced/DND'd remote iPhone where even the wake-push may not surface, the parallel SMS (above) is the reach guarantee.
- **Stale-alert defence:** short FCM `ttl` (120 s) plus an `issued_ts` check in `_bgHandler` — we discard an alert older than its TTL rather than alarm on a hazard that may already be resolved.

### Evacuation guidance

**Approach: pre-mapped per-floor routes, not live indoor positioning.** Justification — reliable indoor positioning during a real fire/gas event is not achievable: WiFi APs may lose power, BLE-beacon trilateration is ±3–8 m at best and degrades in smoke-filled, crowded stairwells, and we will not gate a life-safety instruction on a flaky fix. Instead the HOA pre-maps, per `Floor`, a small set of `EvacuationRoute`s (each ending at an `AssemblyPoint`, Foundation §6) as directed polylines over a floor-plan image.

Rendering and route selection:
- Floor plan + route drawn with **`CustomPainter`** over the plan raster (precise control of the highlighted path, arrows, "you are here" marker; `flutter_map` is overkill for a single static raster and pulls a tile dependency we don't need offline).
- **Route AWAY from the triangulated source:** each `EvacuationRoute` is tagged with the `zone_id`s it passes through. On receiving `triangulated_source_zone_id`, the client filters out any route whose path traverses the source or its immediate neighbours, then picks the shortest remaining route to an `AssemblyPoint`. Selection is done client-side from cached route geometry so it works with no network.

```dart
EvacuationRoute pickRoute(List<EvacuationRoute> routes, String? sourceZone, Set<String> neighbors) {
  final blocked = {if (sourceZone != null) sourceZone, ...neighbors};
  final safe = routes.where((r) => r.zonePath.toSet().intersection(blocked).isEmpty);
  return (safe.isEmpty ? routes : safe).reduce((a, b) => a.lengthM <= b.lengthM ? a : b);
}
```

- **Graceful degradation:** if no `triangulated_source_zone_id` is present, or triangulation confidence is low, or route geometry is missing, the app falls back to the **static building evacuation map** (the legally-posted plan image) plus a plain-text "nearest exit / assembly point" — never a blank screen. We display the triangulation confidence honestly ("Likely source: kitchen, low confidence") rather than implying false precision, because, as the foundation notes, AI source triangulation is an estimate from sparse sensor gradients and can be wrong about *which* unit is the origin.

### "I'm safe / evacuated" check-in (feeds victim accounting)

The check-in is the resident's input to the Occupancy/Accounting reconciliation (Foundation §3). It is reachable from three places: the full-screen alarm screen, the notification actions (`safe`/`help`), and the persistent foreground-service notification.

```dart
// POST /v1/incidents/{incident_id}/checkins   (body below) -> creates CheckIn (Foundation §6)
class CheckInRequest {
  final String incidentId, unitId;
  final CheckInStatus status; // safe_outside | safe_inside | needs_help  (no_response is server-inferred)
  final double? lat, lng;     // only if presence/location consent given
  final DateTime ts;          // client-stamped; lets a queued offline check-in keep its real time
  final String sessionSig;    // HMAC over the canonical check-in, signed with the session key (below)
}
```

Tapping a notification action invokes the background isolate, which enqueues the check-in (below) and POSTs immediately if online. `needs_help` is escalated by the backend straight to the live manager/ISU accounting view. `no_response` is never sent by the client — it is what Accounting infers for residents who never checked in, and is exactly the population reconciled against `OccupancyEstimate` to compute **unaccounted occupants**.

**Integrity and monotonicity of the safe-transition (a `safe_outside` is the record that *removes* a person from the unaccounted list, so it is the highest-trust, hardest-to-forge transition):**

- **Session-bound signing at creation time.** Every `CheckIn` is bound to the authenticated session *when the resident taps*, not just at flush time. On login the device derives a per-session signing key (held in the OS keystore / iOS Keychain); the client computes `sessionSig = HMAC(session_key, canonical(incident_id, user_id, unit_id, status, ts))` at the moment of the tap and stores it in the Isar outbox alongside the record. The backend verifies the signature against the session that was live when the check-in was created, so a queued check-in carries its own authentication and cannot be forged or replayed by anything that did not hold the session key at tap time.
- **Reject out-of-window flushes.** The backend rejects any flushed check-in whose `ts` **predates the incident's `opened_ts`** or **postdates its `resolved_ts`** — a replayed or stale "safe" from before the incident (or after it closed) is never honoured.
- **Monotonic toward caution — never auto-downgrade.** Status transitions move freely *toward* caution but not silently away from it: a `needs_help` from a user is **never silently overwritten by a later `safe_*` from the same user**, and is **never auto-downgraded by a queued or replayed message.** The old `(incident_id, user_id)` last-write-wins dedupe is replaced by a precedence rule — `needs_help` outranks `safe_*`, and clearing a `needs_help` to a safe state requires an **explicit fresh, live (not queued) confirmation** from that same authenticated user (or a manual override by a `hoa_manager`/dispatcher, which is logged in `AuditLogEntry`). A delayed or accidental `safe` can therefore never quietly clear someone who is actually trapped.
- **`safe` is the highest-trust transition.** Because clearing someone from the unaccounted list is exactly the action with the worst failure mode (a trapped person marked safe), `safe_*` is treated as the transition that must be hardest to forge: it must carry a valid session signature, fall inside the incident window, and — when it overrides a prior `needs_help` — be a fresh live confirmation, not a flush from the outbox.

### Presence contribution with explicit consent

The WiFi-presence sensing (Foundation §1) is building-infrastructure (ESP32-S3 CSI/RSSI), not the phone — the app's role is (a) an explicit consent toggle that authorizes the resident's `Unit` to be included in zone occupancy estimates, and (b) optionally sharing the phone's coarse location *during an active incident only* to sharpen accounting. The same in-building presence signal also tells the Notification service whether a resident is inside (covered by edge sirens + gateway panel) or remote (needs parallel SMS, above).

- Consent is **opt-in, per-purpose, revocable**, stored server-side and mirrored locally; the UI states plainly that under normal operation only anonymous per-zone counts exist and identity is unlocked only at `Alarm`/`Evacuation` with an `AuditLogEntry` (Foundation §1/§6).
- **Honest accuracy limit:** WiFi-presence occupancy is a noisy *estimate*. CSI/RSSI counting confuses a phone left at home with a present person, miscounts when several devices belong to one occupant, and cannot identify *who*. The app therefore frames the resident check-in — not presence — as ground truth, and presents presence-derived counts only to managers/ISU as "estimated occupancy," never as a name list.

### Offline / last-known behaviour during an incident

A gas leak can knock out building WiFi and the app may be on cellular-only or fully offline. The app must still alarm, guide, and capture check-ins.

- **Local cache (Isar):** route geometry, floor-plan rasters, assembly points, and the resident's `Unit` linkage are cached so the alarm + evacuation map render with zero network. Isar chosen over Hive for its typed queries and faster cold reads of the route set on a notification cold-start.

```dart
@collection
class CachedRoute {
  Id id = Isar.autoIncrement;
  late String routeId, buildingId, floorId, assemblyPointId;
  late List<String> zonePath;       // for source-avoidance filtering offline
  late List<double> polyline;       // flattened x,y over the cached plan image
  late double lengthM;
}
```

- **Queued check-ins:** if a check-in POST fails, it is written to an Isar outbox and retried by the foreground-service tick and on connectivity regain (`connectivity_plus`). The client `ts` **and the session signature** are preserved so Accounting sees when the resident actually marked safe (not when the network recovered) *and* can verify the queued record was authentically created by that resident's live session. Per the monotonicity rule above, a flushed `safe_*` never auto-downgrades an existing `needs_help` — the outbox can re-send a safe transition, but it cannot silently clear a help request.

```dart
Future<void> submitCheckIn(CheckInRequest r) async {
  await isar.writeTxn(() => isar.outboxCheckIns.put(OutboxCheckIn.from(r))); // durable first (incl. sessionSig)
  unawaited(_flushOutbox()); // best-effort immediate send; foreground tick retries
}
```

- **Last-known incident:** on launch the app reads the cached active-incident snapshot so a resident reopening the app mid-evacuation immediately sees the alarm state and their pending check-in, even before the socket reconnects.

### Resident status view

The home/status surface, driven by `activeIncidentProvider`:
- **Normal:** building-safe banner, last sensor-health summary for the resident's `Unit` (battery/`low_battery`, last-seen from `DeviceHealth`), and the consent toggles.
- **During an incident:** incident state (`Alarm`/`Evacuation`/`Resolution` per Foundation §7), hazard type + affected zones, the selected evacuation route, the resident's own check-in status, and — for residents who manage shared units — the check-in status of co-residents on that `Unit` (so a parent can see a child has not checked in). It never shows other residents' identities beyond the user's own `ResidentUnit` scope; the full unaccounted-occupant picture is the manager/ISU view, not the resident's.

---

## Cross-Cutting: Logging, Security, Integration, Non-Functional

> **As built:** logs go to stdout (Docker json-file, 10 MB × 3 for each hub container), with the JWT in WebSocket URLs kept out of uvicorn's and nginx's logs. The audit log is a plain append-only table: no hash chain, WORM seal or notarization. MQTT and HTTP are plaintext on a trusted LAN/VLAN; sensors log in with per-sensor passwords (no certificates) and people with a username only. No external integration or actuation is wired.

This section deepens the operational and security spine that every other component depends on. It refers to entities (`Incident`, `AuditLogEntry`, `IncidentEvent`, `ExternalIntegration`, `OccupancyEstimate`, `Device`, `CheckIn`), states (`Detection`→`Verification`→`Alarm`→`Escalation`→`Evacuation`→`Resolution`/`FalseAlarm`), topics (`canary/v1/...`), and the latency budget from the Foundation verbatim.

### 1. Logging & Auditability

Two log planes are kept physically and legally distinct, because they have opposing requirements: operational logs are high-volume, mutable, short-lived, and queried for debugging; safety audit logs are low-volume, immutable, long-lived, and queried for liability/forensics after a real fire.

```
                        OPERATIONAL PLANE                          SAFETY AUDIT PLANE
                        (debug / observe)                          (legal / forensic)
   services ──OTel──► Loki + Prometheus ──► Grafana        AuditLogEntry ──► Postgres (hash-chained)
   (JSON, 30–90d, mutable, sampled)                          │
                                                            ├──► near-real-time external notarization
                                                            │     (append-only transparency log /
                                                            │      managed ledger; reachable only by a
                                                            │      sealer role the app DB role cannot assume)
                                                            └──► WORM seal ──► S3 Object Lock (COMPLIANCE)
                                                                  • per-incident entries: near-real-time
                                                                  • routine entries: nightly batch
```

**Operational/system logs.** Structured JSON via `structlog` (Python) → OpenTelemetry → Loki; metrics to Prometheus; traces sampled (tail-based, keep 100% of any trace touching an `Incident`). Every log line carries `trace_id`, `service`, `building_id`, and—if applicable—`incident_id` for correlation across the detection→alert path. Retention 30 days hot / 90 days cold. These logs are **never** the system of record for safety decisions.

**Safety audit logs (`AuditLogEntry`).** Append-only in PostgreSQL, made tamper-evident with a per-building hash chain. Each row's hash covers the previous row's hash, so any deletion or back-dating breaks the chain and is detectable.

```sql
CREATE TABLE audit_log_entry (
  id            BIGGENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  building_id   TEXT NOT NULL,
  incident_id   TEXT,                         -- nullable: some audits are system-level
  seq           BIGINT NOT NULL,              -- per-building monotonic
  ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor         JSONB NOT NULL,               -- {type:user|service|device|external, id, role, auth:'mtls|jwt|system'}
  action        TEXT NOT NULL,                -- e.g. 'incident.transition','identity.unlock','valve.command'
  target        JSONB NOT NULL,               -- {entity, id, from_state?, to_state?}
  identity_unlock BOOLEAN NOT NULL DEFAULT false,
  payload       JSONB NOT NULL DEFAULT '{}',
  prev_hash     BYTEA NOT NULL,               -- SHA-256 of previous row's row_hash (genesis = 32 zero bytes)
  row_hash      BYTEA NOT NULL,               -- SHA-256(canonical_json(this row excl. row_hash) || prev_hash)
  sealed_at     TIMESTAMPTZ,                  -- set when this row's hash is notarized/WORM-sealed; NULL = unsealed window
  UNIQUE (building_id, seq)
);
-- Hardening: REVOKE UPDATE, DELETE on audit_log_entry FROM ALL; only an append role may INSERT.
-- A BEFORE INSERT trigger computes seq, prev_hash, row_hash server-side so the client cannot forge the chain.
-- CRITICAL: the application's DB role is NOT the table owner and is NOT superuser, so it cannot bypass the
-- trigger, alter the table, or disable RLS. Trigger-bypassing privileges (owner/superuser) are held only by a
-- separate, human-gated migration role, never by any running service. This closes the "privileged attacker
-- recomputes the chain forward" hole: no online role can rewrite rows and re-derive a consistent chain.
```

Justification for hash-chain-in-Postgres + WORM seal (vs. running entirely on a managed ledger DB like QLDB): keeps one operational store, works on-prem for HOAs that refuse cloud, and the WORM seal plus external notarization gives the regulator-grade immutability QLDB would—while letting us seal *incident-linked* entries in near-real-time rather than waiting for a nightly batch.

**Tamper-evidence, sealing cadence & external anchoring.** The hash chain alone is only tamper-*evident* to whoever can recompute it; it becomes tamper-*proof* once a row's hash is sealed to an append-only store the application's DB role cannot reach. Two cadences run:

- **Near-real-time seal for incident-linked entries.** Any `AuditLogEntry` written during or immediately after an `Alarm`/`Escalation`/`Evacuation` (and anything carrying that `incident_id`) is sealed within seconds, not at the next nightly batch. Sealing means: (a) appending the row's `row_hash` (and the running chain head) to an **external append-only/transparency log or managed ledger** whose write credential is held only by an isolated **sealer service**—a role the app DB role and on-host services cannot assume—and (b) writing the entry's `row_hash` into the **S3 Object-Lock (COMPLIANCE) WORM** bucket. This collapses the prior ~24h rewrite window for the most damning entries to seconds: even root-on-Postgres cannot rewrite recently-sealed history without the external anchor diverging from the local chain, which is detected.
- **Nightly batch seal for routine entries.** Non-incident, routine audit rows are still batch-exported nightly to WORM with a signed daily "seal" record (the day's last `row_hash` + a count), and that seal hash is anchored back into the chain. This keeps steady-state cost low while incident-time forensics get sub-minute durability.

Verification = recompute the chain locally **and** compare both the daily seals and the external notarization anchors; any mismatch (including a local chain that no longer reconciles with the external append-only log) raises a Sev-1 integrity alert. COMPLIANCE mode means **not even the root account** can delete before retention expiry, and the external anchor means **not even root-on-Postgres** can silently rewrite the unsealed-then-sealed window.

**Audited events (non-exhaustive, all carry `actor`):**

| Event | When | identity_unlock |
|---|---|---|
| `incident.transition` | every `IncidentEvent` state change (Detection→…→Resolution/FalseAlarm) | — |
| `incident.dismiss` | manager/dispatcher marks `FalseAlarm` (reason mandatory) | — |
| `identity.unlock` / `identity.relock` | occupancy data resolved to named residents for victim-accounting | **true** |
| `valve.command`, `hvac.command` | any actuation command issued (see §2 interlocks) | — |
| `external.dispatch` | webhook sent to 112/ISU or gas distributor (+ delivery receipt) | — |
| `auth.role_change`, `auth.privileged_login` | RBAC grant/revoke, admin/dispatcher login | — |
| `device.provision`, `device.cert_rotate`, `device.revoke` | device credential lifecycle | — |
| `device.tamper` | gateway/edge tamper switch tripped (enclosure opened) | — |
| `data.export`, `report.generate` | incident report or PII export produced | sometimes |

**Attribution.** Every entry names a concrete `actor`: a `User` (with role + auth method), a backend `service` (service account), a `Device` (by mTLS cert CN), or an `external` integrator. Automated transitions (e.g. critical-gas fast-path Alarm) are attributed to the named service, never "system" anonymously, so an auto-decision is auditable.

**Retention policy.** `AuditLogEntry` + WORM seals: **10 years** (covers the long tail of Romanian civil-liability and insurance limitation periods after a fatal incident; safety audit must outlive the building's management contract). `OccupancyEstimate`: 30 days normal; identity-resolved accounting snapshots tied to an `Incident` are retained with that incident (10 yr). `SensorReading`: 13 months (TimescaleDB downsampling/continuous aggregates beyond 90 days). Operational logs: 90 days.

**Incident-report export/generation.**

```
GET  /v1/incidents/{incident_id}/report?format=pdf|json   # roles: hoa_manager, dispatcher_external, system_admin
POST /v1/incidents/{incident_id}/report/seal              # freezes a signed, hash-anchored report snapshot
```

The report is reconstructed **only** from `AuditLogEntry` + `IncidentEvent` (the immutable plane), never from mutable operational logs, so it is defensible in court. Contents: full timeline (every state transition with actor + ts), triggering `SensorReading`s with the triangulation verdict and its stated confidence, occupancy/`CheckIn` reconciliation (who was accounted for, who was `unaccounted`), all external dispatches with delivery receipts, and any actuations. The PDF embeds the chain segment hash **and** the external notarization anchor for the incident window, so a recipient can independently verify integrity against a source outside our database. ISU-bound reports are generated automatically on entry to `Escalation`.

### 2. External Integration

All outbound integration goes through one **Escalation/External-integration service** that loads pluggable **adapters**. The core knows only the adapter interface; adding ENGIE, a new ISU regional dispatch API, or a county-level system is a new adapter class + an `ExternalIntegration` row — **zero core changes**.

**Adapter interface contract.**

```python
class IntegrationAdapter(Protocol):
    kind: str            # 'emergency_dispatch' | 'gas_distributor' | 'hvac' | 'gas_valve' | 'home_assistant'
    direction: str       # 'outbound' | 'actuation'

    async def healthcheck(self) -> AdapterHealth: ...
    # Outbound notify: idempotent on (incident_id, integration_id, attempt_key).
    async def dispatch(self, ev: CanonicalIncidentEvent, cfg: IntegrationConfig) -> DispatchReceipt: ...
    # Actuation (HVAC/valve/HA): MUST raise InterlockViolation unless ALL preconditions pass.
    async def actuate(self, cmd: ActuationCommand, cfg: IntegrationConfig, interlock: InterlockToken) -> ActuationReceipt: ...
    def map_status(self, external_response: dict) -> IntegrationStatus: ...   # external ack/decline → our model
```

Key contract rules: (1) `dispatch` is **idempotent** keyed on `(incident_id, integration_id, attempt_key)`—retries never double-dispatch 112. (2) Every `dispatch`/`actuate` returns a receipt persisted as `AuditLogEntry(action='external.dispatch'|'valve.command'...)`. (3) Adapters are sandboxed per `kind` with their own credentials and timeouts; a failing adapter cannot block others (per-adapter circuit breaker, `tenacity` retry with jitter). (4) The canonical event is translated **inside** the adapter, so external API quirks never leak into the core.

**Canonical → external mapping (outbound).** The orchestrator emits one `CanonicalIncidentEvent` on entry to `Escalation`; each adapter maps it:

```json
{
  "schema": "canary.incident.v1",
  "incident_id": "inc_4471", "building_id": "bld_007",
  "hazard_type": "combustible_gas", "severity": "critical", "state": "Escalation",
  "address": {"street":"Str. Exemplu 12","city":"Cluj-Napoca","unit":"unit_0312","floor":"flr_03"},
  "geo": {"lat":46.77,"lon":23.59}, "primary_zone": "zone_kitchen",
  "occupancy": {"persons_est": 4, "checked_in_safe": 1, "unaccounted": 3, "confidence": "low"},
  "opened_ts":"2026-06-15T14:03:25Z", "callback":{"phone":"+40...","incident_url":"https://..."}
}
```

- **112/ISU adapter.** Romania has no public push-to-112 API for private systems today; be honest about this. The buildable design is dual-mode: (a) a **machine-readable webhook** to ISU's incident view (when a regional agreement exists), and (b) a **fallback automated voice/SMS + monitored-station** path (the system phones an alarm-monitoring center / sends SMS to a duty dispatcher) when no API exists. `occupancy.confidence` is sent verbatim and the message states it is an **estimate**, never a count to act on blindly.
- **Gas distributor adapter (ENGIE / Distrigaz Sud).** Webhook with hazard zone + meter/POD reference so the distributor can remotely curtail supply at the building riser. Mapped from `hazard_type ∈ {combustible_gas}`.

**Webhook delivery semantics.** Outbound webhooks are HMAC-SHA256 signed (`X-Canary-Signature`, timestamped to block replay), at-least-once with exponential backoff via a Redis-Streams outbox, and require an ack; unacked after the deadline escalates to the fallback channel and raises a manager alert. Delivery receipts (and non-delivery) are audited.

**Optional actuation: HVAC, automated gas-shutoff valve, Home Assistant.** These are **off by default** and gated, because wrong actuation can *cause* a hazard. There are two distinct ways actuation can make things worse, and the design must address both:

1. **Wrong decision** — closing a valve mid-incident can be correct or wrong depending on context; opening one into a leak is catastrophic.
2. **Ignition by the actuation hardware itself** — *the act of actuating is itself a spark/arc source.* Any electromechanical relay, valve, or HVAC contactor that makes/breaks load can **arc**, and an arc in a gas-saturated atmosphere is an ignition source. This means the mitigation hardware can cause the very explosion it is meant to prevent. Authorization, corroboration, and fail-safe-closed logic do **not** address this hardware-level risk; only certified hardware and spark-free actuation topology do.

**Hardware certification & topology requirements (hard precondition, not advice).** Any valve, relay, or HVAC element that may operate in a potentially flammable atmosphere **must** be intrinsically-safe / explosion-proof, **ATEX-rated** (Ex-certified) for the relevant gas group/zone. Actuation is **refused** (raising `InterlockViolation`) if the target `Device`/`ExternalIntegration` is not certified Ex-rated in its config. Strongly preferred topology for automatic gas-valve closure: a **latched, normally-closed solenoid that closes by de-energizing** (closes on loss of power; no make/break of load *in the atmosphere* during the closing action), so the closure event itself introduces no spark in the hazardous zone. Per the Foundation's Section G regulatory assumption, **any** automatic gas actuation is additionally gated behind explicit regulatory/gas-distributor sign-off. **Until certified hardware and that sign-off are in place, the default action is alarm-only: no automatic valve operation of any kind.**

Actuation flows down the existing downlink topic `canary/v1/{building_id}/cmd/{device_id}` and a Home Assistant adapter (HA REST/WebSocket API + long-lived token) for prosumer setups.

**Safety interlocks — ALL must hold before any `actuate()`; otherwise `InterlockViolation` and audit:**

```
0. Hardware certification: target device/integration is ATEX/Ex-rated for the zone AND (for any automatic gas
   actuation) regulatory/distributor sign-off flag is present. If NOT certified -> refuse, default to alarm-only.
1. Per-building feature flag actuation_enabled == true AND device.actuation_capable == true
2. Incident.state ∈ {Alarm, Escalation, Evacuation}  AND hazard_type matches the actuator's mandate
3. Hazard CORROBORATED (not single-sensor Detection) — uses the same corroboration guard as Verification→Alarm
4. Device healthcheck OK, valve self-test passed within TTL, last command not within debounce window
5. Command-type policy:
     - Gas valve CLOSE: allowed automatically for critical combustible_gas/CO ONLY IF interlock 0 holds
       (Ex-rated + signed-off) AND the closure is via a de-energize-to-close (no in-atmosphere make/break)
       solenoid. Otherwise alarm-only. Valve OPEN: NEVER automatic — human (manager/ISU) only.
     - HVAC: only intrinsically-safe modes (e.g. damper to outside-air / shutdown). Spark-capable equipment
       defaults to DE-ENERGIZE, never energize, in a gas hazard.
6. InterlockToken minted by the Incident orchestrator for THIS incident+device+command, single-use, TTL-bound.
7. Fail-safe default on any ambiguity/timeout: gas valve -> CLOSED (via de-energize); HVAC spark sources -> OFF.
```

Justification: actuation is the one place the platform can physically make things worse—and it can do so two ways, by deciding wrong or by *being the ignition source*. So it is the most conservative path in the system: hardware-certification-gated (interlock 0), corroboration-gated, human-required for any energizing/opening action, fail-safe-closed-by-de-energizing on doubt, and fully audited. Where certified hardware or regulatory sign-off is absent, the platform does not actuate at all and falls back to its always-available floor: the local alarm.

### 3. Security & Privacy

**RBAC (least privilege).** Roles from the Foundation (`resident`, `hoa_manager`, `dispatcher_external`, `system_admin`) enforced at the API gateway via JWT scopes plus row-level checks; the deny-default matrix:

| Capability | resident | hoa_manager | dispatcher_external | system_admin |
|---|---|---|---|---|
| View own unit telemetry/incidents | ✔ (own units only) | ✔ (building) | — | ✔ |
| View building-wide incidents | — | ✔ | ✔ (escalated only) | ✔ |
| Submit `CheckIn` | ✔ | ✔ | — | ✔ |
| Dismiss `FalseAlarm` / order Evacuation | — | ✔ | ✔ | ✔ |
| **Identity-unlock occupancy** | — | only during Alarm/Evac, time-boxed, audited | only during Alarm/Evac, audited | break-glass, audited |
| Issue actuation command | — | ✔ (interlocked) | ✔ (interlocked) | ✔ (interlocked) |
| Manage devices / certs / RBAC | — | — | — | ✔ |

`dispatcher_external` is scoped to a single `Incident` for its active window (token bound to `incident_id`), not the whole building—an ISU dispatcher sees the fire they're handling, nothing else. Identity-unlock is **never** a standing permission; it is a time-boxed, incident-scoped grant that writes `AuditLogEntry(identity_unlock=true)` on grant and auto-relocks on `Resolution`/`FalseAlarm`.

**Encryption.** In transit: TLS 1.3 everywhere (REST/WS, MQTT, webhooks, DB connections); MQTT additionally uses mTLS (below). At rest: PostgreSQL/TimescaleDB volume encryption (LUKS/cloud KMS) plus **application-layer envelope encryption** for the most sensitive columns—identity-resolved occupancy and `ResidentUnit` PII—so a DB dump alone does not expose who-lives-where; keys in KMS/Vault, rotated. WORM audit exports are SSE-KMS encrypted.

**Sensor-node device authentication.**

- **Identity:** every `Device` gets a unique X.509 client certificate (per-device, never shared keys). Private key generated **on-device** in the ESP32-S3 (ideally eFuse/secure-element backed; key never leaves the chip). EMQX enforces **mTLS** + a per-device ACL pinning the cert CN to exactly its own `canary/v1/{building_id}/.../{device_id}/#` topics—a compromised node can neither read others' telemetry nor publish as another device.
- **Provisioning:** factory/installer flow issues a short-lived bootstrap cert; on first connect the device CSRs for its operational cert from an internal CA (e.g., `step-ca`). The installer binds `device_id`→`zone_id` in the app; `device.provision` is audited.
- **Rotation & revocation:** operational certs are short-lived (e.g., 90 days), auto-renewed before expiry over the `cmd` downlink; compromised/decommissioned devices are added to a CRL/OCSP that EMQX checks. `device.cert_rotate` / `device.revoke` audited.

**LoRa end-to-end authentication (gateway is NOT a trust shortcut).** LoRa nodes have no TLS, but device authenticity must **not** terminate at the gateway. The Foundation principle "a fake all-normal is as dangerous as a fake alarm" means a compromised gateway must never be able to forge device-attributed telemetry—including a fabricated "all normal" that suppresses a real hazard, or a fabricated alarm. Therefore:

- **Per-device end-to-end MAC.** Each LoRa node holds a per-device symmetric key (provisioned alongside its cert lifecycle) and computes a **per-frame MAC/signature over the original frame**. The gateway **forwards** that device MAC upstream; it does **not** strip or replace it with its own identity. The **cloud verifies the per-device MAC** against the node's provisioned key, so a reading is only attributed to a device if that device actually signed it. A compromised gateway can drop or delay frames (a detectable availability failure) but cannot mint readings attributed to a device it does not have the key for.
- **Gateway hardening & tamper detection.** Because the gateway is often in an unlocked basement (Foundation Section G), it gets a **locked enclosure with a tamper switch**; opening it raises an audited `device.tamper` event and flags that gateway's stream as suspect.
- **Cross-checks for gateway compromise.** Detection runs consistency checks across transports and event paths—e.g., a gateway suddenly bridging *all-normal* telemetry while the edge `event` topic (or a neighboring building/gateway) indicates a hazard, or device MAC verification failures, raises an integrity alert and treats that gateway's "normal" readings as unverified rather than reassuring.

This removes the previous single-point-of-total-trust: the gateway is a transport and corroboration node, not the authentication authority for device readings.

**Privacy for occupancy/presence data.** This is the platform's sharpest ethical edge, so be explicit.

- **Data minimization by default:** WiFi-presence is processed to an **anonymous per-zone `OccupancyEstimate` count** only. No MAC addresses, no per-device tracking, no packet payloads, no persistent identity are stored in normal operation. CSI/RSSI features are computed at the edge and discarded; only the count + confidence is published.
- **Consent:** residents consent at onboarding to anonymous occupancy sensing for safety; the legal basis under GDPR is **vital interests / life safety** for the incident-time identity resolution, with documented DPIA. Common-area sensing is signposted in the building per Romanian/EU norms.
- **Anonymization & gating:** identity-level resolution (mapping a count/`CheckIn` to named residents for victim-accounting) is **locked** in `Normal`/`Detection`/`Verification`. It unlocks **only** at `Alarm`/`Evacuation`, is time-boxed, incident-scoped, audited (`identity.unlock`), and auto-relocks at `Resolution`/`FalseAlarm`.

**Life-safety vs privacy trade-off (stated plainly).** Under normal conditions privacy wins: the system genuinely cannot identify who is in a room, only how many. During a confirmed life-threatening incident, life safety wins: the system unlocks identity to tell ISU *who is likely still inside* (the core "unaccounted occupants" differentiator). The trade-off is made *acceptable* not by choosing one side permanently but by making the privacy-breaking mode **rare, automatic only on corroborated alarm, narrowly scoped, time-boxed, and fully audited**—so every identity unlock is later reviewable, and a false alarm that triggered an unlock is itself on the record.

### 4. Non-Functional

**Detection-to-alert latency — per-hop, instrumented.** We measure each hop with OpenTelemetry spans and alert on SLO burn. `ingest_ts − device_ts` (from the schema) gives transport+ingest latency; spans cover the rest. Restating the Foundation budget with the instrumentation point and the dominant failure each hop guards against:

| Hop | Budget | Measured by | If it blows the budget |
|---|---|---|---|
| Sample + on-device pre-inference | ≤ 300 ms | device span (fw) | edge still self-alarms; no cloud dependency |
| **Edge-local alarm fire** | **≤ 1 s, cloud-independent** | firmware GPIO timestamp | the guaranteed floor — fires even if all of the below fail |
| Node → gateway (MQTT/WiFi) | ≤ 300 ms | `ingest_ts−device_ts` portion | auto-failover to LoRa (relaxed ≤30 s) |
| Gateway → cloud EMQX | ≤ 500 ms | bridge span | gateway raises local panel; buffers + replays |
| Ingestion validate/dedupe/write | ≤ 400 ms | ingestion span | back-pressure to Redis Stream; detection reads stream directly |
| Detection + Verification | ≤ 1 s (critical fast-path) | detection span | fast-path skips full verification for critical gas/CO |
| Incident open + FCM fan-out | ≤ 1.5 s | notification span | redundant channels (gateway panel + edge siren) cover push |
| **End-to-end physical → resident push** | **≤ 5 s** | end-to-end trace | edge+gateway alarms already audible regardless |

We alert when the rolling p95 of the critical-gas end-to-end trace exceeds 5 s, and page when the edge-local path (the safety floor) is observed > 1 s anywhere.

**High-availability design.**

- **No SPOF on the safety path.** Ingestion, Detection, Notification run ≥2 replicas across ≥2 AZs (target 99.95%). EMQX is a multi-node cluster; PostgreSQL/TimescaleDB run primary + sync standby with automatic failover (Patroni); Redis in Sentinel/Cluster mode.
- **Stateless services, durable queue.** Detection/Notification are stateless and consume from Redis Streams with consumer groups, so a replica dying just reassigns pending messages—no lost telemetry, and dedupe on `(device_id, seq)` makes reprocessing safe.
- **The architectural HA trick is decentralization:** the per-building gateway and the edge nodes are *independent* alarm authorities. Cloud HA protects the monitoring/coordination plane and external escalation, but the building's ability to alarm does **not** depend on cloud uptime at all.

**Fallback behavior, per component failure.**

| Failure | Detection | Fallback behavior | Safety guarantee held |
|---|---|---|---|
| Node WiFi/MQTT down | broker LWT / missed heartbeat | node switches to **LoRa** telemetry; keeps local pre-inference + local alarm | local alarm ≤1 s |
| Gateway WAN down | `gateway/status` stale | gateway **store-and-forwards**; raises **local alarm panel** building-wide on corroborated hazard; replays buffered readings (idempotent on `device_id,seq`) on recovery | building-wide local alarm |
| Gateway compromised/tampered | `device.tamper` event, device-MAC verification failures, cross-check anomaly | gateway's bridged readings treated as **unverified**; per-device MAC still verified end-to-end at cloud so it cannot forge device-attributed telemetry; integrity alert raised; edge `event`-topic + neighboring gateways corroborate true state | no silent fake all-normal |
| Cloud Detection unreachable | health probe / no consumer progress | edge + gateway alarms still fire; cloud opens/updates `Incident` on recovery and reconciles via buffered `seq` | redundant local alarms |
| EMQX cluster degraded | cluster metrics | gateway bridge buffers; nodes fall back to LoRa via gateway; clients reconnect to healthy node | telemetry buffered, alarms local |
| Postgres primary down | Patroni failover | standby promoted (seconds); audit writes block-and-retry (never silently dropped—safety audit must not lose entries) | no audit loss |
| Redis down | connection errors | detection falls back to reading the MQTT stream directly; degraded latency, not degraded safety | alarms still raised |
| FCM/push degraded | FCM delivery receipts | redundant channels: gateway **local panel** + **edge sirens** alert occupants; web console live for managers; SMS fallback for managers | occupants still alerted audibly |
| 112/ISU webhook fails | no ack by deadline | auto-fallback to voice/SMS/monitored-station path; manager paged to call 112 manually; non-delivery audited | escalation still reaches humans |
| Identity/RBAC service down | health probe | fail-closed for all privileged actions (no new identity-unlocks, no actuation) **and** for identity-resolved accounting/roster reads; **only non-sensitive alarm/evacuation instructions to occupants stay open** | alarms reach occupants; PII never leaks unaudited |

**Auth-degraded read policy (split, not "reads remain open").** "Read paths remain open" is too coarse for the alarm path, because some reads are exactly the privacy-sensitive, unlock-gated data. We split read paths explicitly:

- **Open without auth (not sensitive):** alarm/evacuation *instructions to occupants*—"there is a gas alarm, evacuate via route X to assembly point Y," local siren/panel state, all-clear. These must never be gated on auth; they carry no PII and a degraded RBAC service must never silence or withhold them.
- **Fail closed even when RBAC is down (sensitive):** identity-resolved accounting and the unaccounted-occupant **roster**. These are `incident_unlock`-gated, audited reads; when RBAC/Audit is degraded—precisely when controls are weakest—they must **not** be served, because an open read would bypass the `incident_unlock` gate and its `identity.unlock` audit entry. We accept that ISU may temporarily lose the *named* roster (falling back to anonymous counts) rather than leak identity-resolved data unaudited.

The invariant across every failure mode, restated from the Foundation: **a real hazard always produces a local audible/visual alarm within ≤ 1 s, independent of cloud, gateway, network, auth, or push availability.** Everything else—coordination, escalation, accounting, audit—is layered on top and degrades gracefully without ever silencing that floor, and without ever leaking identity-resolved data unaudited or trusting unverified telemetry as reassuring.

---

## Phased Delivery Roadmap

> **As built:** the hub implements the software path of P1–P2 in one process on the Pi (rule-based detection, the incident state machine through `evacuation`, check-ins, accounting, the manager/dispatcher console and the resident app) plus the rule-based first stage of P5 (triangulation, radar occupancy, false-alarm reduction). Not built: the gateway's local alarm panel and signage and push delivery (P1), LoRa and store-and-forward replay (P3), external escalation adapters (P4), learned models (P5). The edge-local alarm is the firmware's own (air: buzzer and LED; water: buzzer and valve). Nothing has run in a live building yet.

The build order follows one rule: the safety-critical path (`detection -> alert -> evacuation -> victim-accounting`) ships before anything else, and within it, the parts that save lives with the least machinery ship first. Concretely, that means the **edge-local fail-loud alarm** and a **thin detection -> push -> check-in slice** come before the cloud `Incident` state machine is complete, and rule-based detection comes well before any learned triangulation or presence model. One piece of resilience is not deferred: the gateway's cloud-independent building-wide alarm ships with the MVP, because it is the backstop the whole safety story rests on the moment the system is live in a real building. AI features are deliberately the last two phases, because they sit on top of data the earlier phases generate and validate.

Six phases. Phase 0 proves the riskiest hardware assumption in a lab. Phase 1 is the deployable MVP, and it already carries gateway autonomy for the building-wide alarm. Phases 2-4 complete the human-facing safety path, harden the wider network (LoRa telemetry, store-and-forward replay), and add external escalation. Phase 5 layers the two differentiators (triangulation, presence accounting) once the data and the human-in-the-loop are real.

```
P0 Lab bench    P1 Thin-slice MVP    P2 Full alert+evac   P3 Network        P4 External    P5 AI
detection->     detection->push->    ->evacuation->       resilience:       112/ISU +      triangulation
local alarm     check-in + gateway   victim-accounting    LoRa telemetry,   gas distrib    + presence accounting
(no cloud)      building-wide alarm   (full state machine) buffer/replay     (Escalation)   (learned, staged)
   │            (cloud, rule-based)        │                   │               │              │
   │                  │                    │                   │               │              │
   └─ fail-loud ──────┴──── safety path + cloud-independent backstop ──────────┴── on top ────┘
```

The edge node's own fail-loud alarm is an absolute floor, not a statistical target. The foundation states the invariant as "a real hazard always produces a local audible/visual alarm within <= 1s, regardless of cloud or gateway state." This roadmap holds the firmware to that wording: the <= 1s edge-local bound is a hard deadline, validated against the slowest observed case, never a p95 that lets one alarm in twenty miss the floor.

---

### Phase 0 — Edge fail-loud, bench-validated (no cloud)

**Goal.** Prove the single most safety-critical and most uncertain assumption before writing backend code: an ESP32-S3 node can sense a real combustible-gas/CO event and fire a local siren/strobe (and drive the valve relay) within the <= 1s edge-local hard deadline, with no gateway and no cloud.

**Scope / deliverables.**
- ESP32-S3 firmware (ESP-IDF/C) for `combustible_gas` and `co` sensor types: a sampling-and-alarm loop designed to a deterministic worst-case execution time, on-device threshold pre-inference producing `edge_state` (`normal | warn | alarm`), local alarm driver (siren/strobe + solenoid relay), self-test on boot.
- Canonical `canary.telemetry.v1` JSON serializer and the `.../event` publish on `edge_state` transitions (validated against a local Mosquitto, no cloud yet).
- `seq` persistence across reboot via NVS, plus the `health.epoch` counter so a post-reboot `seq` reset is not later misjudged as a duplicate.
- Bench rig: controlled gas source (calibrated CH4/LPG and CO test gas), instrumented latency capture from physical exposure to siren-on, run across the temperature, sensor warm-up, and battery conditions that stress the alarm loop's timing.

**Components built.** Edge firmware (gas/CO), local alarm path, telemetry/event serializer. Nothing cloud-side.

**Exit criteria.**
- Every induced critical gas/CO exposure fires the local alarm, with the worst observed physical-to-siren latency <= 1s across the full test matrix (temperature, warm-up state, battery level), not just the median. The 1s figure is committed as a worst-case bound, consistent with the foundation's "always": the slowest case is the one that must pass, since for a life-safety floor the tail is the whole point.
- Sensor warm-up and cross-sensitivity characterized; documented false-positive rate from cooking/aerosols at the chosen `warn`/`alarm` thresholds.
- Node sounds the alarm with WiFi and the broker both unplugged (cloud independence demonstrated, not assumed).

**Team / skills.** 1 embedded engineer (ESP-IDF/C), 1 hardware/sensors engineer with gas-sensing experience, part-time safety/test lead.

**Top risks.** (1) Gas-sensor accuracy is the hard limit of the whole product. MEMS/electrochemical sensors drift, need warm-up, and cross-react (alcohol, aerosols, humidity); the `warn`/`alarm` thresholds are a false-alarm-vs-miss tradeoff that must be set on real data, not datasheet numbers. (2) Worst-case alarm latency, not average latency, is the spec. A loop that is fast on the bench at room temperature but slow during sensor warm-up or on low battery fails the invariant even if its p95 looks fine; the firmware must hit the deadline in the slowest condition. (3) CO and combustible-gas need different sensor chemistries and response curves; do not assume one tuning fits both. (4) Driving a mains gas solenoid from a hobby-grade relay is a real electrical-safety and liability concern; treat the valve cutoff as optional and certified separately.

---

### Phase 1 — Thin-slice MVP: detection -> push -> check-in, with gateway autonomy (one building)

**Goal.** Prove the end-to-end safety loop on minimal hardware in one live building: a few real nodes detect a hazard, the cloud opens an `Incident`, residents get a push alert within the <= 5s WiFi/cloud budget, and a resident can check in. Because this is a real building, not a lab, the cloud-independent backstop ships in the same phase: with the WAN cut, the gateway still corroborates and raises a building-wide alarm on the local panel. This is the smallest thing that is both demoable and safe to deploy.

**Scope / deliverables.**
- Minimal hardware: ~6-10 nodes across 3-4 units plus 2 common-area zones in one building, gas + CO + leak. WiFi/MQTT only for node-to-gateway transport (LoRa telemetry deferred to Phase 3). One gateway running Mosquitto store-and-forward.
- **Gateway autonomy for the building-wide alarm:** gateway-local corroboration logic plus the **local alarm panel**, so a corroborated hazard raises a building-wide alert without the cloud. The gateway buffers telemetry while the WAN is down and is the cloud-independent authority for the local panel. (Full store-and-forward replay/reconciliation hardening and LoRa stay in Phase 3; the autonomous alarm itself does not wait.)
- Cloud EMQX bridged from the gateway broker; **Ingestion** service: schema validation against the Pydantic `canary.telemetry.v1` contract, `(device_id, seq)` dedupe, write `SensorReading` to TimescaleDB, latest value to Redis.
- **Rule-based Detection only**: per-`sensor_type` detection and critical thresholds, no AI. A reading crossing a threshold opens an `Incident` and drives a reduced state path `Detection -> Verification (single re-sample) -> Alarm`.
- **Notification** service: FCM push to residents on `Alarm`, with an actionable "Are you safe?" prompt.
- Flutter resident app, vertical slice: receive push, open incident view, submit a `CheckIn` (`safe_outside | safe_inside | needs_help | no_response`).
- Minimal data model in PostgreSQL: `Building/Floor/Unit/Zone/Device`, `User/ResidentUnit` (manual provisioning is fine), `Incident`, `IncidentEvent`, `CheckIn`, `Notification`.
- Minimal manager web view: live list of open `Incident`s and incoming `CheckIn`s (read-mostly).

**Components built.** Ingestion, rule-based Detection, Incident orchestrator (reduced), Notification, gateway corroboration + local alarm panel, Flutter check-in flow, minimal web read view, minimal RBAC. Edge firmware from Phase 0 reused as-is; its local alarm runs in parallel and unconditionally.

**Exit criteria.**
- A real induced gas/CO event produces a resident push at <= 5s end-to-end (95th percentile) on the WiFi/cloud path, measured via the `device_ts -> ingest_ts -> notification-sent` chain. (The <= 5s cloud-path push is a p95 SLO; the <= 1s edge-local alarm remains the hard floor and is unaffected.)
- **With the WAN cut at the gateway, a corroborated hazard raises the building-wide alarm on the local panel** with no cloud reachable. This is a P1 exit criterion: the system is not deployable to a real building without its cloud-independent backstop.
- A resident receives the push and submits a `CheckIn` that lands in PostgreSQL and shows on the manager view, all within one incident.
- Duplicate/out-of-order readings are correctly deduped on `(device_id, seq)` (replay a captured stream to confirm).
- Edge-local alarm still fires when the gateway is killed mid-test (Phase 0 invariant holds in the integrated system).

**Team / skills.** Embedded (carryover), 1-2 backend (Python/FastAPI, MQTT, TimescaleDB), 1 gateway/edge integrator for the corroboration + panel logic, 1 Flutter, 1 frontend (React, read-only view), part-time DevOps. ~4-6 people.

**Top risks.** (1) Push reliability and latency on real mobile networks/OEMs (Doze mode, FCM throttling) can blow the <= 5s budget; the edge siren, the gateway local panel, and a manager-visible state are the backstops, and all three must be wired from day one. (2) Two alarm authorities now exist in P1 (edge node and gateway panel); define clearly that the gateway raises the building-wide alert on corroboration while each node fires its own local alarm independently, so they reinforce rather than fight. (3) False alarms from naive single-threshold rules erode trust fast; keep residents on the `Alarm` notification only after a confirming re-sample, never on first `Detection`. (4) Scope creep: full LoRa, buffered-replay reconciliation, `Escalation`, and `Evacuation` are explicitly out of this phase. What is in scope is the gateway raising a building-wide alarm with the WAN cut, because that is the part the live deployment cannot do without.

---

### Phase 2 — Complete the safety path: evacuation + victim-accounting

**Goal.** Finish the human-facing safety loop: the full `Incident` state machine through `Evacuation`, evacuation guidance to residents, and victim-accounting that reconciles check-ins against an occupancy baseline so a manager can see who is unaccounted for.

**Scope / deliverables.**
- Full `Incident` state machine per the foundation: `Detection -> Verification -> Alarm -> Evacuation -> Resolution`, plus `FalseAlarm`, with every transition appending an `IncidentEvent`. Add the critical fast-path (`value >= critical threshold` or `edge_state == "alarm"` skips full verification into `Alarm`).
- Multi-sample / neighboring-zone corroboration in `Verification` (still rule-based, no AI triangulation yet).
- `EvacuationRoute` / `AssemblyPoint` data model and resident-app evacuation guidance on `Evacuation`.
- Victim-accounting v1: an occupancy **baseline per zone** (start with a manually maintained roster from `ResidentUnit`, not WiFi-presence yet), reconciled against `CheckIn` records to compute and display unaccounted occupants live to managers.
- `AuditLogEntry` for every transition and for the identity-unlock authorized on `Alarm`/`Evacuation`. Manager actions: confirm, order evacuation, dismiss as `FalseAlarm` with reason.
- Manager web console upgraded from read-only to an operational incident console (acknowledge, order evacuation, mark resolved/false).

**Components built.** Full Incident orchestrator, Verification (rule-based corroboration), Occupancy/Accounting service (roster-based baseline), Evacuation guidance, Audit, full manager console.

**Exit criteria.**
- A confirmed gas/CO incident drives the full path to `Evacuation`, residents receive route + assembly-point guidance, and the unaccounted-occupants count updates live as check-ins arrive.
- A manager can dismiss a `Detection`/`Verification` event as `FalseAlarm` with a logged actor and reason; no silent regression out of `Alarm` exists (forward-only invariant verified by test).
- Every transition and every identity-unlock has a matching `AuditLogEntry`.
- Tabletop evacuation drill in the pilot building completes with accurate accounting.

**Team / skills.** Backend (state machine, accounting), Flutter (evacuation UX), frontend (operational console), plus a domain advisor familiar with Romanian *asociație de proprietari* evacuation procedure and ISU expectations. ~4-6 people.

**Top risks.** (1) Roster-based occupancy is only as good as the roster; stale `ResidentUnit` data produces wrong "unaccounted" numbers that first responders may act on — label the baseline's provenance and confidence explicitly. (2) Evacuation routing in a real building is non-trivial (blocked stairwells, the hazard sitting on the route); keep routes statically authored and reviewed per building, not auto-generated. (3) `FalseAlarm` handling is where trust is won or lost; the dismissal flow must be fast and audited.

---

### Phase 3 — Network resilience: LoRa telemetry + buffered replay

**Goal.** Harden the parts of degraded-mode operation that P1 did not already cover. P1 delivered the cloud-independent building-wide alarm; this phase delivers the rest of the foundation's fallback promises: WiFi loss at the node falling back to LoRa telemetry, lossless buffered replay on WAN recovery, and clean cloud reconciliation after an outage.

**Scope / deliverables.**
- LoRa radio on nodes plus a LoRa concentrator on the gateway; the compact CBOR frame (short integer keys, per-building 16-bit ID mapping, enum-coded `sensor_type`/`edge_state`/`units`, quantized `value`, delta `device_ts`) and gateway-side re-expansion back to canonical `canary.telemetry.v1` JSON.
- Node connectivity state machine: WiFi/MQTT primary, automatic switch to LoRa for telemetry on link loss, continued local pre-inference and local alarm throughout.
- Gateway store-and-forward buffering with replay on WAN recovery (dedup is automatic via `(device_id, seq)`). The independent local alarm panel from P1 is extended here only insofar as buffered/replayed readings must reconcile cleanly; the autonomous building-wide alarm itself already shipped in P1.
- `gateway/status` heartbeat and WAN-state reporting; cloud reconciliation that opens/updates the `Incident` from replayed buffered readings after an outage.

**Components built.** LoRa firmware path + CBOR codec, gateway concentrator + buffer + replay, cloud reconciliation-on-recovery. (Gateway local alarm panel was built in P1; this phase hardens its interaction with replayed data.)

**Exit criteria.**
- With WiFi down at a node, telemetry continues over LoRa and a hazard still produces a local alarm within the <= 1s hard deadline and a best-effort cloud alert <= 30s (the relaxed LoRa budget).
- With WAN down at the gateway, the P1 building-wide local-panel alarm fires as before, and buffered readings now replay and reconcile cleanly (no duplicate `Incident`, no lost readings) when WAN returns.
- Cloud-detection outage test: edge + gateway alarms fire; cloud opens the correct `Incident` on recovery from the replayed stream.

**Team / skills.** Embedded (LoRa, RF), backend (buffering/replay/reconciliation), DevOps (chaos/failure-injection testing). ~3-4 people.

**Top risks.** (1) LoRa duty-cycle limits (EU 868 MHz regulations) and interference mean LoRa is a degraded telemetry channel, not a real-time one; never let any part of the <= 5s budget depend on it. (2) Replay-and-reconcile is a classic source of duplicate or split incidents; the `(device_id, seq)` idempotency and `epoch` handling must be exercised hard with fault injection. (3) Two alarm authorities (cloud and gateway) already coexist from P1; on reconnection, define which one owns the resident-facing `Incident` state so the replay does not double-alert or conflict.

---

### Phase 4 — External escalation: 112/ISU and gas distributors

**Goal.** Close the path to emergency services and utilities: the `Escalation` state, machine-readable incident hand-off to 112/ISU and the relevant gas distributor (ENGIE / Distrigaz Sud), and the external incident view.

**Scope / deliverables.**
- `Escalation` state and its guards (critical gas/CO, alarm persisting past the escalation timer, or unaccounted occupants > 0), with `Alarm -> Escalation` and `Escalation -> Evacuation` transitions.
- `ExternalIntegration` model and the Escalation/External-integration service: signed, retried, machine-readable incident webhooks carrying hazard type, severity, location path, affected zones, and live unaccounted-occupant count.
- External web incident view for dispatchers (`dispatcher_external` role), scoped strictly to escalated incidents, with the gated/audited identity-level accounting unlocked only while the incident is active.
- `Resolution` guard tightened for escalated incidents to require external/manager acknowledgement.

**Components built.** Escalation service, external webhook egress (sign/retry/dead-letter), external dispatcher view, `ExternalIntegration` config and RBAC for `dispatcher_external`.

**Exit criteria.**
- A critical escalated incident delivers a machine-readable payload to a sandbox `ExternalIntegration` endpoint with retry and signature verification; the dispatcher view renders it with live accounting.
- Identity-level accounting is visible to a dispatcher only while the incident is active and every access is in `AuditLogEntry`.
- An escalated incident cannot reach `Resolution` without the required acknowledgement.

**Team / skills.** Backend (integrations, RBAC, audit), frontend (dispatcher view), plus a stakeholder liaison for 112/ISU and gas-distributor integration agreements and data formats (the real-world blocker here is institutional, not technical).

**Top risks.** (1) Integrating with 112/ISU and utilities is a procurement, legal, and protocol problem far more than a code problem; build to a sandbox/mock contract and do not gate the rest of the product on a signed agreement. (2) False escalations to emergency services carry legal and trust consequences; escalation guards must be conservative and every escalation must be human-reviewable and reversible up to the point of dispatch. (3) Privacy/GDPR exposure peaks here — identity unlock crossing an organizational boundary needs the time-box and audit to be airtight.

---

### Phase 5 — AI features: hazard-source triangulation and presence accounting

**Goal.** Add the two differentiators only now that there is corroborated incident data, a reconciled accounting baseline, and a human in the loop to catch model error. Both ship as **advisory overlays on top of the rule-based path**, never as the sole trigger for `Alarm` or escalation.

**Scope / deliverables.**
- **AI hazard-source triangulation** in `Verification`: estimate the likely leak origin zone from the spatial/temporal gradient of multi-sensor `SensorReading`s. Stage it: first a deterministic gradient/heuristic estimator, then a learned model (trained on Phase 1-4 incident data plus induced-event captures) once enough labeled events exist. Output is a ranked zone list with confidence, shown to managers/dispatchers as guidance.
- **Presence-based accounting**: replace (or fuse with) the roster baseline using anonymous per-zone `OccupancyEstimate` from `wifi_presence` devices. Stage it: start with simple RSSI/CSI count heuristics feeding `persons_est` + `confidence`; introduce a learned occupancy model only after collecting per-building calibration data. The Occupancy/Accounting service reconciles `OccupancyEstimate` against `CheckIn` to refine unaccounted-occupant counts.
- Confidence surfaced everywhere these estimates appear; both features remain off the critical trigger path.

**Components built.** AI triangulation service (heuristic then learned), learned occupancy model + per-building calibration pipeline, fusion of presence estimates with the Phase 2 roster baseline, confidence UI.

**Exit criteria.**
- Triangulation names the correct origin zone in a documented majority of induced multi-zone events, with calibrated confidence; managers/dispatchers see it as ranked guidance, and turning it off does not change whether `Alarm`/`Escalation` fire.
- Presence-based `OccupancyEstimate` improves unaccounted-occupant accuracy over the roster baseline on a held-out set, with reported error bars; identity-level resolution stays gated, audited, and time-boxed per the foundation.
- A documented accuracy/limitations report ships with the feature (see honesty note below).

**Team / skills.** ML engineer(s) (signal processing, scikit-learn/ONNX, the same toolchain as the on-device models), backend (serving, fusion), plus labeled-data collection effort (induced events, calibration walkthroughs). ~3-4 people.

**Top risks and an honest accuracy limit.** This is where the product must not oversell.
- **Triangulation is approximate.** With a handful of sensors per building, gas dispersion is nonlinear, sensors saturate, and HVAC/airflow distorts gradients. Expect a ranked guess, not a coordinate. It is decision support for responders, never an authoritative "the leak is here." If it ever suppressed an alert or narrowed a search incorrectly, that is a safety failure, so it stays advisory and additive only.
- **WiFi presence is unreliable for life-safety counting.** RSSI/CSI occupancy estimation is sensitive to device count per person (zero for a sleeping child, two for one adult), multipath, furniture, and wall materials; counts drift and confidence is often low. It is useful as a *hint that a zone may not be empty*, and dangerous if treated as a roster. Victim-accounting must always present WiFi-presence as low-confidence corroboration alongside, never instead of, `CheckIn` records — a "0 estimated" zone is never treated as "confirmed empty."
- **Cold-start.** Both learned models need data the earlier phases produce; shipping them earlier would mean shipping an unvalidated model on the safety path, which is exactly the ordering this roadmap exists to prevent. Hence they are last, and each begins as a heuristic before any learned variant.

---

Cross-cutting note: each phase carries its own observability (the OpenTelemetry/Prometheus latency SLO tracking for the detection-to-alert budget) and its own failure-injection tests, rather than deferring resilience and monitoring to a final hardening phase — for a life-safety system, those are exit criteria, not afterthoughts. The one resilience guarantee that is never deferred is the cloud-independent local alarm: the edge node's <= 1s hard floor from P0 and the gateway's building-wide panel from P1 are both in place before the system is ever live in an occupied building.

---

## Open Questions, Assumptions & Trade-offs

This section is a deliberate confession of what we do *not* yet know and what we chose *despite* knowing better. But it opens with one resolution, because the rest of the plan cannot stand without it. The shared foundation's earlier sections read in places as if this platform is a certified life-safety system — auto valve cutoff, automated 112 dispatch, "self-defending safety system," fail-loud guarantees. **It is not, and until a stakeholder says otherwise in writing, the whole platform is built and marketed as an advisory, supplementary system that supplements — never replaces — the mandated, independently-certified standalone detectors every unit must still have.** This is not a footnote buried in §1.G; it is the default posture the entire foundation now adopts, and the items below are gates that can further invalidate cost, topology, and certification assumptions before a single ESP32-S3 is provisioned.

### 0. The resolution that the rest of the plan depends on (read first)

The most dangerous failure mode for this project is not a technical one. It is shipping an architecture written *as if* certified while the legal reality is *advisory* — because that combination encourages residents to remove the standalone CO/gas detectors the law (and physics) still require, trading a certified device for an uncertified one and ending up less safe than before we arrived. The plan must not straddle the two answers. We pick one as the default and re-scope the other as an explicit, costed programme.

**Default (what we build now): advisory / supplementary.** Concretely, this is not a stance — it changes the foundation's artifacts:

- **Executive summary (§1).** The opening line must state, in the product's own voice, that the platform *supplements and does not replace* certified standalone detectors, and that the "self-defending safety system" framing describes the *building-monitoring* goal, not a certified life-safety guarantee. The phrase "certified" must not appear in marketing or UI unless a notified body has signed off (question 1.D).
- **Auto gas-valve cutoff (§1, §2, §5 `cmd`/valve).** **Gated OFF by default.** Automatic solenoid actuation of a gas shutoff is not enabled in the advisory build; the default fail-safe action on a confirmed hazard is *alarm only*. Valve actuation is a per-building opt-in that requires licensed gas-technician / distributor (ENGIE/Distrigaz) sign-off before it can be turned on, because mis-actuation carries its own safety and liability profile (re-ignition, loss of heating in winter). The `cmd` valve channel ships, but disabled and audited.
- **Automated 112/ISU dispatch (§3, §7 `Escalation`).** **Gated OFF as a direct machine path.** 112 in Romania is a human-answered emergency line; there is no default PSAP API. The `Escalation` state therefore targets a **human** — a monitoring-center operator or HOA manager who then phones 112 — not a machine-to-machine dispatch. Direct PSAP integration is only enabled if and when ISU confirms an API exists (question 1.D).
- **Every resident-facing and manager-facing UI** carries a persistent, non-dismissable disclaimer: *"Advisory system. Keep your certified standalone CO and gas detectors. This app supplements them; it does not replace them."* Onboarding requires acknowledging this.
- **The `≤1 s` fail-loud edge alarm and `≤5 s` cloud-push budgets (§8) stand**, but are described as *best-effort engineering targets of an advisory aid*, not as certified life-safety guarantees, since no notified body has validated them.

**Alternative (only if a stakeholder commits in writing): certified life-safety system.** This is *not* a config flag. It is a re-architecture plus a certification programme — confirming and meeting EN 50291 (CO), EN 50194 / EN 50244 (combustible gas), and EN 54 (fire detection/alarm components) where any fire-alarm claim is made, plus the Romanian transpositions, under a notified body or accredited Romanian lab, with explicit liability ownership. Choosing this path re-scopes timeline and budget by **months and a notified-body relationship**, mandates certified (not hobbyist MEMS) sensing hardware, and only then unlocks the valve-cutoff, direct-dispatch, and "certified" marketing claims. We do not build to this contract speculatively; we build advisory and convert deliberately.

Three foundation guarantees in §2/§8 are only true once their corresponding open questions (1.B/1.E below) are resolved; until then they are aspirations, not guarantees, and we mark them as such:

- **WAN-availability** gates the `≤5 s` cloud-push budget and the cloud control plane's 99.9% availability (§8).
- **Gateway physical ownership/security** gates the building-local-authority autonomy promise (a gateway in an unlocked basement is a single point of physical compromise for the whole building's safety plane).
- **Data residency** gates the choice of cloud region and managed services for `SensorReading`/`OccupancyEstimate`/`CheckIn` (§6).

These three are pulled up here, not left in the list below, precisely because each invalidates a concrete §2/§8 guarantee rather than merely sizing a component.

### 1. Open questions / clarifications needed from stakeholders

Grouped by the decision they block. Each is phrased so a stakeholder can answer it and so the answer changes the build.

**A. Scale & topology (blocks: data-store sizing, gateway spec, EMQX cluster sizing in §4)**

- **How many buildings in the pilot, and the 24-month target?** 1 building vs 50 vs 5,000 changes everything: a single-tenant Docker Compose box is fine for a pilot; the foundation's K8s + multi-AZ EMQX cluster is over-built for 1 building and under-specified for 5,000.
- **Nodes per building and per zone?** The `canary/v1/{building}/{floor}/{unit}/{zone}/{device}` topic tree and the `≤5 s` latency budget (§8) assume a bounded fan-out. A 200-unit block with gas+CO+leak+presence per kitchen is ~800 devices/building; at LoRa duty-cycle limits the fallback path cannot carry that load (see trade-off §3.E). We need the real node count to confirm the LoRa fallback is even viable at scale.
- **What is the expected `wifi_presence` device density per zone?** CSI/RSSI occupancy estimation accuracy collapses below a minimum AP/anchor density. If the answer is "one ESP32-S3 per unit," the `OccupancyEstimate.confidence` will be low enough that victim-accounting (§3) is advisory at best (see §3.D honesty note).

**B. Deployment model (blocks: §2 architecture, data residency, ops cost) — resolves two of the three §0 guarantee gates**

- **Central cloud vs on-prem gateway-per-building vs hybrid?** The foundation assumes **hybrid** (gateway + cloud). We need explicit confirmation, because:
  - If HOAs reject cloud dependency or recurring cloud cost, the answer is **gateway-as-primary** with cloud-as-optional-reporting, which moves Detection/Incident logic onto the gateway and changes §7's home.
  - If a single central cloud is mandated (no per-building gateway), we lose the WAN-outage autonomy promised in §8 and must re-justify the `≤1 s` fail-loud guarantee on the edge node alone.
- **Who owns and physically secures the gateway? (§0 guarantee gate.)** A gateway in an unlocked basement is a single point of physical compromise for the whole building's safety plane. Until an owner and a securable, powered, lockable location are named per building, the building-local-authority autonomy in §2/§8 is an aspiration, not a guarantee. **Required answer:** a named responsible party (HOA/managing agent), a locked utility/technical room, and tamper detection on the gateway enclosure.
- **Data residency: must `SensorReading`/`OccupancyEstimate`/`CheckIn` stay in-country (RO/EU)? (§0 guarantee gate.)** This constrains the cloud region and possibly forbids non-EU managed services. Until answered, the §4 managed-EMQX / managed-Postgres choices are provisional. **Default assumption pending confirmation:** EU-region only, GDPR-bound (see assumption 11); any non-EU managed service is disallowed until explicitly cleared.

**C. Budget (blocks: hardware BOM, ops staffing, redundancy depth)**

- **Hardware budget per node and per gateway?** Certified life-safety gas/CO sensing (e.g., EN 50291 for CO, EN 50194 for combustible gas) costs materially more than hobbyist MEMS modules. The foundation lists "MEMS/electrochemical" without committing — and per §0 the *advisory* default explicitly does **not** claim these are certified detectors, so the BOM can start with non-certified sensing *as long as the advisory disclaimer holds*. Committing to certified sensing is part of the certification-programme branch, not the default build.
- **Recurring ops budget?** 99.95% multi-AZ (§8) for the safety path, EMQX cluster, 24/7 on-call, and TimescaleDB at scale are real monthly costs. Who pays — the HOA, a SaaS fee, a utility, a grant?
- **Who funds the LoRa fallback infrastructure** (concentrators, spectrum/duty-cycle compliance, gateway radios)?

**D. Regulatory, ISU & insurance certification (blocks: the certified-vs-advisory branch in §0)**

- **Is this a *certified life-safety system* or an *advisory/supplementary* system?** Answered *by default* in §0 as **advisory**; this question is the written commitment that would flip us to the certification branch. Everything below is what that branch must resolve.
- **Which standards must the life-safety function meet?** Candidates: EN 50291 (CO), EN 50194 / EN 50244 (combustible gas), EN 54 (fire detection/alarm system components) if any fire-alarm claim is made, and the relevant Romanian transpositions. **We have not confirmed which apply** — and under the advisory default we do not need to, because we make no certified-detector claim.
- **Who certifies the life-safety function, and who carries liability when it fails?** A notified body? An accredited Romanian lab? The HOA's insurer? If no certified body signs off, the platform stays advisory (the §0 default) and must not be marketed as a detector.
- **Will ISU/112 accept machine-to-machine incident ingestion at all?** Per §0, the default is **no** — `Escalation` (§7) notifies a *human* (monitoring-center operator / HOA manager) who then calls 112. This question confirms whether ISU offers any API/PSAP integration that would let us enable the direct machine path. **Most likely the answer keeps us on the human-mediated default.**
- **Auto gas-valve cutoff (solenoid relay, §1/§2):** per §0 this is **gated OFF by default**. The open question is the precise condition to enable the per-building opt-in: is automatic actuation of a gas shutoff legally permitted, and under what licensed gas-technician / distributor (ENGIE/Distrigaz) authorization? Mis-actuation has its own safety and liability profile (re-ignition, loss of heating in winter).
- **False-alarm liability to ISU:** what is the cost/penalty regime for dispatching emergency services on a false alarm? This directly tunes the `Verification` guards in §7 and the human-in-the-loop step in §0's escalation default.

**E. Connectivity assumptions (blocks: §8 fallback guarantees) — resolves the third §0 guarantee gate**

- **Does each building have reliable WAN (fiber/4G) for the gateway? (§0 guarantee gate.)** The `≤5 s` cloud path and the cloud control plane's 99.9% availability (§8) assume it. If not, gateway-local authority (§3.C) becomes mandatory, not optional, and the cloud-push budget is downgraded to best-effort. Until a per-building WAN baseline is confirmed, treat the `≤5 s` figure as an aspiration on the cloud path only; the `≤1 s` edge-local alarm does not depend on it.
- **Is LoRa spectrum/duty-cycle usage (EU868) acceptable and licensed for this deployment density?** The 1% duty cycle caps how much telemetry the fallback can carry; at high node counts the LoRa path is alarm-only, not telemetry-complete.
- **Is in-building WiFi for the ESP32-S3 nodes the platform's responsibility or the resident's?** Residents' home routers are unmanaged, unreliable, and reboot at will. A dedicated safety SSID/VLAN per building is strongly preferred but adds cost (question C).

**F. Floor-plan & spatial data (blocks: AI triangulation §3.D, evacuation routing)**

- **What is the authoritative source of floor-plan geometry?** AI hazard-source triangulation and `EvacuationRoute`/`AssemblyPoint` guidance are only as good as the spatial model. Options, none confirmed: cadastral/HOA blueprints (often paper-only, decades old), manual survey at install time, or no geometry (zone-adjacency graph only). **Assume no usable digital floor plans exist** until proven otherwise.
- **What spatial fidelity do we actually have — metric coordinates, or just a zone-adjacency graph?** Triangulation degrades from "likely room" to "likely floor" depending on this answer (see §3.D).

**G. Product positioning — already resolved in §0, restated here for completeness**

- **Advisory aid or certified life-safety system?** **Resolved: advisory by default** (see §0). We build to the *advisory* contract — the platform *supplements* mandated, independently-certified standalone detectors (which residents must still have) and never claims to replace them; every UI and contract states this. Flipping to "certified life-safety system" later is not a config change — it is a re-architecture plus a certification programme costing months and a notified-body relationship, undertaken only on a written stakeholder commitment (question 1.D).

### 2. Key assumptions made in this plan

Stated so they can be falsified. If any is wrong, the cited foundation element must change.

1. **Hybrid deployment is acceptable** (per-building gateway + cloud), and each building has a securable, lockable, powered location for a gateway with a named responsible owner. *(Drives all of §2; gates the §0 gateway-autonomy guarantee.)*
2. **Bounded scale per building** — on the order of hundreds (not thousands) of `Device` nodes per building — so the EMQX bridge, Ingestion dedupe on `(device_id, seq)`, and the `≤5 s` budget hold. *(Drives §5, §8.)*
3. **The platform is advisory/supplementary, not a certified replacement for mandated detectors — this is the default, not an interim state.** Residents retain independently-certified standalone CO/gas detectors, and the executive summary, every UI, and every contract say so. Valve cutoff and direct 112 dispatch are gated OFF. *(Drives §1 principles and executive summary, all UI disclaimers, liability posture, §2/§5/§7; see §0.)*
4. **Escalation to 112/ISU is human-mediated.** The `Escalation` state's path to 112/ISU (§7) targets a **monitoring-center operator or HOA manager who phones 112**, not a direct PSAP API, until ISU integration is confirmed in writing. *(Re-scopes §3 alert path and §7 `Escalation` notify targets; see §0.)*
5. **WiFi-presence yields zone-level occupancy *counts* with modest confidence, not per-person identity.** Identity-level resolution is unavailable under normal operation and is *approximated* via `CheckIn` reconciliation only. *(Drives §3 accounting, §6 `OccupancyEstimate`, the privacy gate in §1.)*
6. **Automatic gas-valve cutoff is gated OFF by default and is an opt-in per building requiring local technician/distributor sign-off**; the default fail-safe action is *alarm*, with valve actuation enabled only by configuration and regulatory clearance. *(Conditions §1/§2 edge actuation; see §0.)*
7. **A dedicated, managed in-building network (safety SSID/VLAN) exists or will be provisioned** for the nodes — i.e., we are not riding residents' home WiFi for the safety path. *(Drives §8 fallback realism.)*
8. **Mains power with battery backup at each node**, consistent with `battery.powered:"mains"` in the §5 schema being the common case; pure battery nodes are the exception and have a degraded telemetry duty cycle.
9. **FCM push is reachable for most residents most of the time**, but is never the *sole* alarm channel — edge siren + gateway panel cover its failure (§8). *(Justifies redundant alarm paths over investing in push reliability alone.)*
10. **No usable digital floor-plan geometry exists at install time**; spatial model starts as a hand-built zone-adjacency graph, upgraded opportunistically. *(Caps §3.D triangulation claims.)*
11. **Romanian/EU data-protection (GDPR) applies, and data is EU-region-resident by default** for presence and check-in data; the identity-unlock audit trail (`AuditLogEntry.identity_unlock`) is a compliance requirement, not a nice-to-have, and no non-EU managed service is used until data residency is explicitly cleared. *(Drives §1, §6; gates the §0 data-residency guarantee.)*
12. **WAN reliability per building is unconfirmed**; the `≤5 s` cloud-push budget and the 99.9% cloud-control-plane availability (§8) are treated as best-effort aspirations until a per-building WAN baseline is established, while the `≤1 s` edge-local alarm has no WAN dependency. *(Gates the §0 WAN-availability guarantee.)*
13. **One Python/FastAPI stack is operable by the team** — i.e., the team has (or will hire) Python+ML skills, not just JS. *(Justifies §4 backend choice.)*

### 3. Trade-offs behind the major decisions

For each, what we chose, what we gave up, and the honest failure mode.

**A. Backend stack — Python/FastAPI over Node/NestJS**

- **Chose:** one Python stack so triangulation/occupancy ML, edge-model training, and the API share an ecosystem (§4).
- **Gave up:** Node's larger pool of real-time/I/O engineers and arguably tighter WebSocket/event-loop ergonomics; a smaller, more uniform I/O footprint.
- **Honest failure mode:** Python's GIL and async maturity mean the high-throughput MQTT consumer / Ingestion hot path can become a bottleneck before the ML services do. Mitigation: keep Ingestion thin (validate + dedupe + write), push CPU-bound ML to separate worker processes/services, and treat the `≤5 s` budget (§8) as a load-test gate, not an aspiration. If Ingestion can't hold the budget under realistic fan-out (assumption 2), carve it out into Go/Rust — accepting the polyglot cost we tried to avoid.

**B. Data stores — Postgres + TimescaleDB + Redis**

- **Chose:** TimescaleDB *as a Postgres extension* so the time-series and system-of-record share one engine, cutting ops surface (§4); Redis for sub-second hot values/features and as the internal work queue (§3).
- **Gave up:** the raw ingestion throughput and compression of a purpose-built TSDB (e.g., ClickHouse), and a hardened durable broker (e.g., Kafka) for the internal queue. Redis Streams as the safety-path work queue is a deliberate simplicity bet, not a durability bet.
- **Honest failure mode:** at high building/node counts, co-locating TS and relational load on one Postgres can cause the time-series write volume to starve the system-of-record (incident writes, RBAC). And a Redis failure mid-incident could drop queued detection work. Mitigation: separate the TimescaleDB instance from the SoR Postgres early; make the safety path tolerant of Redis loss by also persisting `IncidentEvent` transitions to Postgres synchronously (the source of truth for §7 is Postgres, never Redis). Re-evaluate ClickHouse/Kafka only when measured throughput demands it — not preemptively.

**C. Edge-local vs cloud alarm authority**

- **Chose:** **edge-local has unconditional alarm authority** — a node fires its siren in `≤1 s` regardless of cloud/gateway state (§1, §8); the cloud `Incident` machine (§7) *reconciles* rather than *gates* the physical alarm. Note that under the §0 advisory default, "alarm" here means *audible/visual local alarm only* — the gas-valve relay is gated OFF and does not actuate automatically.
- **Gave up:** centralized suppression of false alarms. An edge node that mis-fires will sound the building before any cloud verification can dismiss it. We accept a *higher false-alarm rate at the edge* as the price of never silencing a real hazard.
- **Honest failure mode:** edge false alarms erode trust and, repeated, train residents to ignore the siren (the classic smoke-alarm-removed-battery problem) — and, dangerously, could prompt them to disable the very standalone detectors §0 insists they keep. Mitigation: tune edge `edge_state:"alarm"` thresholds conservatively for *local siren only*, keep building-wide escalation and any (human-mediated, per §0) ISU notification behind cloud/gateway corroboration (§7 `Verification` → `Alarm` → `Escalation`), and never let an edge false alarm auto-escalate to emergency services. The split is deliberate: **edge can wake you up; only corroborated logic can summon a human who calls for help.**

**D. AI ambition vs reliability — and the liability of acting on low-confidence triangulation**

- **Chose:** ship AI hazard-source triangulation and presence-based accounting as **decision-support overlays**, computed in the cloud `Verification` state, surfaced with explicit `confidence`, and **never on the critical detect→alarm path**.
- **Gave up:** the headline "we pinpoint the leak / we know exactly who's inside" claim. We intentionally under-promise — consistent with the §0 advisory posture.
- **Brutally honest accuracy limits:**
  - *Triangulation:* with sparse sensors and (per assumption 10) only a zone-adjacency graph rather than metric geometry, the realistic output is "leak most likely in zone X / on floor Y," not a coordinate. Gas disperses non-linearly with HVAC, doors, and stack effect; gradient-based source localization from a handful of point sensors is **inherently low-resolution and can be confidently wrong.**
  - *WiFi presence (CSI/RSSI):* occupancy *counting* from CSI/RSSI is noisy, sensitive to furniture/wall changes, device-count rather than person-count biased, and degrades sharply at low anchor density (question A). It is an **estimate with wide error bars**, not a census.
- **The liability line, drawn explicitly:** first responders and the incident UI must **never** treat triangulation or presence counts as ground truth for life-safety decisions. Acting on a low-confidence "zone X is clear" or "0 people inside" could send responders to the wrong room or stand them down while someone is trapped — a directly life-threatening error with clear liability. Therefore: (1) `OccupancyEstimate` is always shown *with* `confidence` and *always* reconciled against authoritative `CheckIn` data (§3); (2) "unaccounted occupants" defaults to **err-on-the-side-of-presence** (treat unknown as possibly-inside, never as empty); (3) every identity-unlock and every AI-derived figure shown to the human who relays to ISU is labeled as *estimate* and logged in `AuditLogEntry`. **The AI makes the human faster; it never makes the decision.**

**E. Privacy vs life-safety for presence data**

- **Chose:** anonymous zone-level occupancy counts under normal operation; identity-level resolution **gated, time-boxed, and audited**, unlocked only when an `Incident` reaches `Alarm`/`Evacuation` (§1, §6).
- **Gave up:** richer everyday analytics (per-resident presence history would improve accounting accuracy and enable "is grandma home?" features) and some accounting precision — anonymous counts reconciled against voluntary `CheckIn`s are fuzzier than continuous identity tracking would be.
- **Honest failure mode & residual risk:** continuous WiFi-presence sensing is *inherently* privacy-invasive even when "anonymized" — occupancy patterns reveal when units are empty (burglary risk), sleep/work schedules, and cohabitation. The anonymization is a policy and processing boundary, not a cryptographic guarantee; a compromised gateway or a malicious admin with unlock rights could de-anonymize — which is precisely why the gateway's physical ownership and securing (question 1.B, §0 guarantee gate) is a privacy control, not just an availability one. Mitigations: process CSI/RSSI to counts **at the edge/gateway** so raw signal features never persist centrally; keep all presence/check-in data EU-region-resident (assumption 11) pending data-residency confirmation; make identity-unlock require an *active high-severity incident state* (not a manual toggle); enforce time-boxing and mandatory `AuditLogEntry.identity_unlock` records; and give residents transparency/opt-out for the *presence* sensor specifically — with the explicit, disclosed consequence that opting out degrades their victim-accounting coverage. This is the one place where we let life-safety **override** privacy by default, and we document exactly when and why.

---

**The one decision that overrides all the others (resolved, not deferred):** this is an **advisory, supplementary** safety platform, not a certified life-safety system, and it is built and marketed as such by default — valve cutoff gated OFF, 112 dispatch human-mediated, "certified" claims withheld, and a persistent UI disclaimer that residents must keep their independently-certified standalone detectors. We do not straddle the two answers. Building it as if it were certified — and being wrong — is the worst available outcome, because it would encourage residents to remove the detectors the law (and physics) still require. Converting to a certified system is a deliberate, written, re-scoped programme (question 1.D), never a silent assumption baked into the architecture.
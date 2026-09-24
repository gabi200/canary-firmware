# Hardware integration: ESP32 sensors → Raspberry Pi hub

How the real Canary firmware (`../water_sensor`, `../air_sensor`) reaches the hub
over MQTT, how the hub stores and analyzes it, and the API the web dashboard
([`web/README.md`](../web/README.md), raw + analysis) and the mobile app
([`mobile/README.md`](../mobile/README.md), analysis only) consume. Overview:
[`README.md`](../README.md). Running the hub and provisioning the sensors:
[`RUNME.md`](../RUNME.md). Checks and MQTT troubleshooting: [`DEBUG.md`](../DEBUG.md).

```
ESP32 air / water ──MQTT──▶ Mosquitto (Pi) ──▶ backend (FastAPI)
                                                 ├─ raw status history (node_status)
                                                 ├─ canonical readings → detection → incidents
                                                 ├─ analysis (per node / zone / building)
                                                 └─ REST + WebSocket
                                  web dashboard ◀┤  raw + analysis
                                  mobile app    ◀┘  analysis only
```

## 1. MQTT topics (produced by the firmware — do not change)

Each device has a configurable base topic `<base>` (portal field "MQTT base
topic"). Defaults: water `water-sensor`, air `canary`. **Every device on the
broker needs a unique base topic.**

| Topic | Direction | Retained | Payload |
| --- | --- | --- | --- |
| `<base>/availability` | device → hub | yes | `online`; last will `offline` |
| `<base>/status` | device → hub | yes | status JSON (below); on change + heartbeat (air 15 s, water 60 s) |
| `<base>/command/result` | device → hub | no | command result JSON (ignored by the hub for now) |
| `<base>/valve/set`, `<base>/buzzer/set` | hub → device | never retain | not used by the hub yet |

The hub subscribes to `#` (setting `CANARY_MQTT_SUBSCRIBE`, default `#`) and
dispatches by topic suffix. Legacy `canary/v1/.../telemetry|event` messages
(`canary.telemetry.v1`, used by `simulator/simulate.py`) keep working.

The device kind is detected from the status document shape:
- **air**: object has `co`, `gas` and `particulate` objects.
- **water**: object has `sensor` and `valve` objects.
- anything else on `.../status` (e.g. the plain string `online`) is ignored.

### Water status document (ESP32-C3, `water_sensor/StatusJson.cpp`)

```json
{"device":{"name":"water-sensor","firmware":"1.0.0"},"uptime_ms":123456,
 "sensor":{"adc":312,"initialized":true,"state":"dry","wet_threshold":1200,"dry_threshold":600},
 "leak_latched":false,
 "valve":{"requested":"open","applied":"open","relay_active":false},
 "alarm":{"state":"inactive","sounding":false,"remaining_seconds":0},
 "wifi":{"connected":true,"rssi":-58},
 "mqtt":{"enabled":true,"connected":true},
 "ota":{"in_progress":false}}
```

Vocabularies: `sensor.state` = `uninitialized|dry|wet`; `valve.*` = `open|closed`;
`alarm.state` = `inactive|sounding|silenced|timed_out`.

### Air status document (ESP32-S3, `air_sensor/StatusJson.cpp`)

```json
{"device":{"name":"canary","firmware":"1.0.0"},"uptime_ms":600000,"warmup_remaining_seconds":0,
 "co":{"ppm":3,"peak_ppm":7,"state":"ok","warn_ppm":50,"danger_ppm":100,"valid":true,"age_ms":800},
 "gas":{"adc":640,"peak_adc":910,"state":"ok","warn_adc":1500,"danger_adc":2200},
 "particulate":{"pm1_0":4,"pm2_5":7,"pm10":9,"peak_pm2_5":31,"peak_pm10":44,"state":"ok",
                "warn_pm2_5":35,"danger_pm2_5":150,"warn_pm10":100,"danger_pm10":250,"valid":true,"age_ms":900},
 "climate":{"temperature_c":22.4,"humidity_percent":41.5,"valid":true,"age_ms":900},
 "presence":{"detected":true,"moving":false,"stationary":true,"moving_distance_cm":0,"moving_energy":0,
             "stationary_distance_cm":142,"stationary_energy":61,"detection_distance_cm":142,"valid":true,"age_ms":120},
 "alarm":{"state":"inactive","hazard":"none","sounding":false,"silence_remaining_seconds":0,
          "self_test":false,"led_color":"green","led_on":true},
 "wifi":{"connected":true,"rssi":-61},
 "mqtt":{"enabled":true,"connected":true},
 "ota":{"in_progress":false}}
```

Vocabularies: channel `state` (`co`, `gas`, `particulate`) = `warmup|ok|warning|danger|fault`;
`alarm.state` = `inactive|warning|sounding|silenced`; `alarm.hazard` = `none|co|gas|particulate`;
`alarm.led_color` = `off|green|blue|cyan|magenta|orange|red|white`.
`gas.adc` is a raw, uncalibrated MQ5 ADC count (0–4095), **not ppm**. No wall
clock on the devices: the hub timestamps on receipt.

## 2. Nodes (physical devices) and channels

A **node** is one physical ESP32, keyed by its MQTT base topic and
auto-registered on its first status document.

- `node_id` = base topic lowercased, runs of non `[a-z0-9]` replaced by `-`,
  trimmed (`canary` → `canary`, `home/Air 1` → `home-air-1`). On a slug clash
  with a different base, append `-` + first 6 hex of sha1(base).
- New nodes land in `CANARY_DEFAULT_BUILDING_ID` (default `bld_007`) /
  `CANARY_DEFAULT_ZONE_ID` (default `zone_hallway`); move them with `PATCH /nodes/{id}`.
- Each node owns logical `Device` rows (so existing floor plan / device health
  views keep working), id `{node_id}:{channel}`:

| Node kind | channel | sensor_type | value | units |
| --- | --- | --- | --- | --- |
| air | `co` | `co` | `co.ppm` | `ppm` |
| air | `gas` | `combustible_gas` | `gas.adc` | `adc` |
| air | `particulate` | `particulate` (new) | `particulate.pm2_5` | `ug/m3` |
| air | `presence` | `radar_presence` (new, occupancy) | 1 if `presence.detected` else 0 | `persons_est` |
| water | `leak` | `water_leak` | 1 if `sensor.state == "wet"` else 0 | `bool` |

New vocabulary: `SensorType.particulate` (hazard; `HazardType.particulate`,
label **"Smoke / particulates"**, not auto-evacuating) and
`SensorType.radar_presence` (occupancy like `wifi_presence`, never a hazard).

### Status document → canonical readings

- One raw snapshot row per accepted status document (`node_status`: node_id, ts,
  uptime_ms, payload JSON verbatim).
- Dedupe/reboot: if `uptime_ms` equals the node's last stored value it is a
  duplicate (retained re-delivery) → ignore. If it is lower → reboot →
  `boot_epoch += 1`. Canonical readings use `epoch = boot_epoch`, `seq = uptime_ms`.
- Retained status messages do not refresh `last_seen_ts` (except on first
  registration); availability seen before registration is remembered and applied.
- Edge state from the device grading: `danger → alarm`, `warning → warn`,
  `ok → normal`. Channels in `warmup`/`fault`, or with `valid == false`, produce
  **no** canonical reading (still kept in the raw snapshot).
- Air readings carry the device's own thresholds (the installer calibration):
  `detection = warn_*`, `critical = danger_*`, `clear = warn_*` (co: `warn_ppm`/
  `danger_ppm`; gas: `warn_adc`/`danger_adc`; particulate: `warn_pm2_5`/`danger_pm2_5`).
  Readings without thresholds (water, legacy) use the backend defaults, and so do
  readings whose thresholds fail the sanity check below.
- Water: reading only when `sensor.initialized`; `edge_state = alarm` when wet,
  else `normal`. A latched-but-dry sensor clears the incident; the latch and the
  closed valve are reported by the analysis layer instead.
- Presence readings only when the value changed or ≥ 5 min since the last one.
- Location (floor/unit/zone) comes from the node's zone.

### Safety rules for hardware readings

Enforced in `backend/app/detection/thresholds.py` and `backend/app/incidents/service.py`:

- **Device thresholds only when sane.** They are used only if all three are finite and
  `0 < clear <= detection < critical`, which for the air node is the firmware's own
  `0 < warn < danger` check. Otherwise the backend defaults apply, so a broken or
  spoofed document cannot make a normal value critical or an incident impossible to clear.
- **A device alarm is never downgraded.** `danger` → edge `alarm` is critical whatever
  the thresholds say. A reading counts toward clearing only with edge `normal` and a
  value below `clear`.
- **Only a device that reported the hazard can clear its incident**, after
  `CANARY_CLEAR_HOLD_SAMPLES` (default 3) consecutive clearing readings. Another node's
  normal heartbeat never gives the all-clear, so an incident whose source went silent
  stays open until a manager or dispatcher resolves it.
- **Smoke / particulates raise `alarm` but never auto-evacuate**, like water leaks. Only
  critical CO and combustible gas go to `evacuation` on their own.
- **Resident messages for water leaks and smoke do not say "evacuate"**: leak → avoid the
  area, the valve has shut the water off; smoke → check for fire, leave and call 112 if
  there is one.
- One open incident per hazard type per building: a second node reporting the same
  hazard joins the open incident (and corroborates it).

## 3. Analysis vocabulary (shared by dashboard and mobile)

Levels / statuses: `ok`, `attention`, `danger`, `unknown` (indicator only).
Node, zone and building `status` is one of `ok|attention|danger`.

`NodeAnalysis`:
```json
{
  "node_id": "canary", "kind": "air", "name": "canary", "zone_id": "zone_kitchen",
  "online": true, "stale": false, "last_seen_ts": "2026-09-23T12:00:00Z",
  "status": "ok", "headline": "Air is good",
  "advice": ["..."],
  "indicators": [
    {"key": "air_quality", "label": "Air quality", "level": "ok", "value": "Good", "detail": "AQI 39", "trend": "stable"}
  ]
}
```
`trend` is `rising|falling|stable|null`; `detail` is optional (`null`).

Indicator keys, in this order:
- **air**: `air_quality`, `co`, `gas`, `comfort`, `occupancy`, `health`
- **water**: `leak`, `valve`, `health`

| key | values (level) |
| --- | --- |
| `air_quality` | `Good`, `Moderate` (ok) · `Unhealthy for sensitive groups`, `Unhealthy` (attention) · `Very unhealthy`, `Hazardous` (danger); a device `particulate.state` of `warning`/`danger` above the AQI's own level shows `Particulate warning` (attention) / `Particulate alarm` (danger); `Sensor fault` (attention), `No data` (unknown). `detail` = `AQI <n>` from the worse of PM2.5/PM10 (EPA breakpoints, instant reading). |
| `co`, `gas` | `Safe` (ok) · `Elevated` (attention) · `Dangerous` (danger) · `Warming up` (unknown) · `Sensor fault` (attention) · `No data` (unknown, invalid/stale) |
| `comfort` | `Comfortable`, `Too cold`, `Too warm`, `Too dry`, `Too humid` or a `, `-joined combination; attention only at extremes (T < 16 or > 30 °C, RH > 70 %); `No data` (unknown) |
| `occupancy` | `Occupied` / `Empty` (ok) · `Unknown` (unknown) |
| `leak` | `No leak` (ok) · `Leak detected` (danger) · `Leak cleared — inspect` (attention, dry but latched) · `Sensor not ready` (unknown) |
| `valve` | `Open` (ok) · `Closed` (attention) · `Unknown` (unknown); keeps the last known position while stale/offline |
| `health` | `Online` (ok) · `Warming up` (ok, `detail` e.g. `3 min left`) · `Weak Wi-Fi` (attention, rssi < -80) · `Stale` (attention, no status for 3× heartbeat: air 45 s, water 180 s) · `Offline` (attention) |

Stale/offline nodes: hazard indicators become `No data`/`unknown`, node status `attention`.
EPA AQI breakpoints (concentration → index):
PM2.5 (2024): 0–9.0→0–50, 9.1–35.4→51–100, 35.5–55.4→101–150, 55.5–125.4→151–200, 125.5–225.4→201–300, 225.5–325.4→301–500.
PM10: 0–54→0–50, 55–154→51–100, 155–254→101–150, 255–354→151–200, 355–424→201–300, 425–604→301–500.

**Analysis payloads never contain raw measurements** (no ppm, ADC, µg/m³,
°C, %RH, RSSI, distances). The only number allowed is the AQI in `detail`
and time remaining in `health.detail`.

## 4. REST API (prefix `/api/v1`, bearer JWT)

| Method | Path | Roles | Response |
| --- | --- | --- | --- |
| GET | `/buildings/{id}/summary` | any authenticated (resident included) | `BuildingSummary` — **analysis only** (mobile + dashboard) |
| GET | `/buildings/{id}/nodes` | hoa_manager, dispatcher_external, system_admin | `NodeOut[]` — raw + analysis (dashboard) |
| GET | `/nodes/{node_id}/history?minutes=60&fields=a,b` | hoa_manager, dispatcher_external, system_admin | `NodeHistory` (dashboard) |
| PATCH | `/nodes/{node_id}` body `{"zone_id"?: str, "name"?: str}` | hoa_manager, system_admin | `NodeOut`; 404 unknown node, 400 unknown zone |

Timestamps (`*_ts`, `ts`) are timezone-aware UTC with a `Z` suffix
(`2026-09-23T12:00:00Z`), on SQLite as well as Postgres. Device data is stamped on
receipt by the hub (§1).

`BuildingSummary`:
```json
{
  "building_id": "bld_007", "generated_ts": "2026-09-23T12:00:00Z",
  "status": "ok", "headline": "All clear",
  "nodes_total": 2, "nodes_online": 2, "active_incidents": 0,
  "zones": [
    {"zone_id": "zone_kitchen", "zone_label": "Bucatarie", "status": "ok", "occupied": true,
     "nodes": [NodeAnalysis, "..."]}
  ]
}
```
Building status: the worse of (an open incident in `alarm|escalation|evacuation` → `danger`,
any other open incident → `attention`) and the worst zone status. Headline:
the most severe open incident's title, else the worst node headline, else
`All clear`. No nodes at all → `attention`, `No sensors connected`. `zones` lists
only zones that contain nodes; `occupied` is `null` when the zone has no air node.
**Residents** never see occupancy (who is home stays manager/dispatcher-only, like
`/occupancy`): for them `occupied` is always `null` and `occupancy` indicators are omitted.

`NodeOut`:
```json
{"id": "canary", "kind": "air", "mqtt_base": "canary", "name": "canary", "firmware": "1.0.0",
 "building_id": "bld_007", "zone_id": "zone_hallway", "online": true,
 "last_seen_ts": "2026-09-23T12:00:00Z", "boot_epoch": 1,
 "status": {"...": "latest raw status document, verbatim, or null"},
 "analysis": NodeAnalysis}
```

`NodeHistory`:
```json
{"node_id": "canary", "minutes": 60, "fields": ["co.ppm", "particulate.pm2_5"],
 "points": [{"ts": "2026-09-23T11:00:15Z", "values": {"co.ppm": 3, "particulate.pm2_5": 7}}]}
```
`minutes` 1–10080 (default 60). Fields are dotted paths into the raw document;
booleans become 0/1, missing → `null`. Points ascending, downsampled to ≤ 360.
Default fields — air: `co.ppm`, `gas.adc`, `particulate.pm1_0`,
`particulate.pm2_5`, `particulate.pm10`, `climate.temperature_c`,
`climate.humidity_percent`, `presence.detected`; water: `sensor.adc`, `leak_latched`.

## 5. WebSocket (`/api/v1/ws/incidents?building_id=&token=`)

Existing `incident` and `checkin` events are unchanged. New event after every
processed hardware status/availability message (analysis only, no raw values):

```json
{"type": "node", "building_id": "bld_007", "node_id": "canary", "kind": "air",
 "zone_id": "zone_kitchen", "online": true, "status": "ok", "ts": "2026-09-23T12:00:00Z"}
```

Clients refetch `summary` (and, on the dashboard, `nodes`/`history`) on `node`
events, throttled; clients must ignore unknown event types. (The `ts` of `incident`
and `checkin` events is also UTC, written `+00:00` instead of `Z`.)

The hub sends each frame to all of a building's sockets at once, with a 2 s limit per
socket: a client that stalls misses that frame (it catches up on its next refetch), and
a broken socket is dropped.

## 6. Settings (`CANARY_*`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `CANARY_MQTT_HOST` / `_PORT` | `localhost` / `1883` | broker |
| `CANARY_MQTT_USERNAME` / `_PASSWORD` | unset | hub's broker credentials |
| `CANARY_MQTT_SUBSCRIBE` | `#` | subscription filter for hardware + legacy topics |
| `CANARY_DEFAULT_BUILDING_ID` / `_ZONE_ID` | `bld_007` / `zone_hallway` | where new nodes land |
| `CANARY_CLEAR_HOLD_SAMPLES` | `3` | consecutive clearing readings, from a device that reported the hazard, before its incident closes |
| `CANARY_RETENTION_DAYS` | `14` | hourly, in batches of 2000 rows, delete `node_status`, `sensor_readings` and `occupancy_estimates` rows older than this; `0` disables. Incidents, events, check-ins and the audit log are never pruned |

Under docker compose, `docker-compose.yml` fixes the MQTT connection (enabled, broker
`mosquitto:1883`, user `hub`; the password comes from `.env`) and uses SQLite at
`/data/canary.db` unless `.env` sets `CANARY_DATABASE_URL`. Every other setting can be
added to `.env`.

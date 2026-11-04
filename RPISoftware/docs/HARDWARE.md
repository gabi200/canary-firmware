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
| `<base>/command/result` | device → hub | no | `{"command","accepted":true,"state"}` or `{"command","accepted":false,"error"}`; matched to the hub's command (§4) |
| `<base>/valve/set`, `<base>/buzzer/set`, `<base>/gas-detector/set` | hub → device | never retain | sent by `POST /nodes/{id}/commands` (QoS 1): air `buzzer/set` `TEST`\|`SILENCE`, `gas-detector/set` `DETECTOR_ON`\|`DETECTOR_OFF`; water `valve/set` `OPEN`\|`CLOSE`, `buzzer/set` `SILENCE` |

The hub subscribes to `#` (setting `CANARY_MQTT_SUBSCRIBE`, default `#`) and
dispatches by topic suffix. Legacy `canary/v1/.../telemetry|event` messages
(`canary.telemetry.v1`, used by `simulator/simulate.py`) keep working.

The device kind is detected from the status document shape:
- **air**: object has `co`, `gas` and `particulate` objects.
- **water**: object has `sensor` and `valve` objects.
- anything else on `.../status` (e.g. the plain string `online`) is ignored.

**Relayed status (ESP-NOW backup link).** A sensor that loses its MQTT session
sends its status document over ESP-NOW; any sensor that still has MQTT
republishes it, verbatim, on the origin's `<base>/status` (retained), using its
own broker login. Nothing on the hub changes: the broker has no ACLs, and a live
document sets the node online again after its last will. Several relays can
publish the same document, and the uptime dedupe drops the copies. Two documents
sent closer together than a relay hop can arrive out of order, which the hub
reads as a reboot (`boot_epoch + 1`). Commands are not relayed. Details:
[`../../water_sensor/README.md`](../../water_sensor/README.md) ("ESP-NOW backup link").

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
 "gas_detector":{"alarm":false},
 "alarm":{"state":"inactive","hazard":"none","sounding":false,"silence_remaining_seconds":0,
          "self_test":false,"led_color":"green","led_on":true},
 "wifi":{"connected":true,"rssi":-61},
 "mqtt":{"enabled":true,"connected":true},
 "ota":{"in_progress":false}}
```

Vocabularies: channel `state` (`co`, `gas`, `particulate`) = `warmup|ok|warning|danger|fault`;
`alarm.state` = `inactive|warning|sounding|silenced`; `alarm.hazard` = `none|co|gas|particulate`;
`alarm.led_color` = `off|green|blue|cyan|magenta|orange|red|white`.
`gas.adc` is a raw, uncalibrated MQ5 ADC count (0–4095), **not ppm**.
`gas_detector.alarm` is the external household gas detector's relay contact:
`true` when it is alarming **or its wiring is open** (fail-safe, the two are
not distinguished). Firmware 1.2.1 adds boolean `gas_detector.enabled`; disabled
inputs report effective `alarm:false`. This setting is persisted per node; fresh configurations
default disabled, while stored configurations without it keep enabled behavior. It is independent
of `alarm.*`, which covers the device's own sensors only. Documents carry no wall-clock time: the hub timestamps on
receipt. The air node syncs SNTP (from the MQTT host first) only to shorten
warm-up after a power cut under 30 s; see `air_sensor/README.md`.

Firmware 1.1.0 (both devices) adds `wifi.ip`, the device's IPv4 address, while
Wi-Fi is connected (`"wifi":{"connected":true,"rssi":-58,"ip":"192.168.1.40"}`).
The hub only offers it as a suggestion for firmware pushes (§4, Firmware): staff
pin the address the hub sends to.

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
| air | `gas_detector` | `combustible_gas` | 1 if `gas_detector.alarm` else 0 | `bool` |
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
- Gas detector (firmware 1.1.0+, the external detector's relay contact): `edge_state =
  alarm` when `gas_detector.alarm` is true, else `normal`, with thresholds detection 0.5 /
  critical 1 / clear 0.5. An open contact is therefore critical combustible gas and goes
  to `evacuation` like an MQ5 `danger`, even though it also reads open when the wiring
  is cut. Older firmware sends no `gas_detector` object and produces no reading.
  Explicit `gas_detector.enabled:false` skips this channel entirely; absent or malformed
  `enabled` retains the alarm behavior above. MQ5, CO and particulate channels remain active.
  Nodes registered before this channel existed get its Device row on their next status
  document after a hub start.
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
| GET | `/buildings/{id}/summary` | any authenticated (resident: own building only) | `BuildingSummary` — **analysis only** (mobile + dashboard) |
| GET | `/buildings/{id}/nodes` | hoa_manager, dispatcher_external, system_admin | `NodeOut[]` — raw + analysis (dashboard); each with `last_command` (command item or `null`; also on summary `zones[].nodes[]`, where residents see `requested_by_name` only for their own commands) |
| GET | `/nodes/{node_id}/history?minutes=60&fields=a,b` | hoa_manager, dispatcher_external, system_admin; resident (own unit + common areas, environmental fields) | `NodeHistory` (dashboard charts, mobile sparklines) |
| PATCH | `/nodes/{node_id}` body `{"zone_id"?: str, "name"?: str}` | hoa_manager, system_admin | `NodeOut`; 404 unknown node, 400 unknown zone |
| POST | `/nodes/{node_id}/commands` body `{"command": "TEST"\|"SILENCE"\|"OPEN"\|"CLOSE"\|"DETECTOR_ON"\|"DETECTOR_OFF"}` | system_admin; hoa_manager/technician (their buildings); DETECTOR_ON/OFF staff only (residents 403); resident (other commands, nodes in zones of their own units, not common areas; else 404); dispatcher 403 | 202 `{"command_id", "node_id", "command", "status": "sent", "sent_ts"}`; 422 not a command of that node kind (air TEST/SILENCE/DETECTOR_ON/DETECTOR_OFF, water OPEN/CLOSE/SILENCE), 409 node offline or detector configuration unsupported (latest status lacks boolean gas_detector.enabled; update firmware), 429 < 3 s after the node's last command, 503 broker not connected |
| GET | `/nodes/{node_id}/commands?limit=20` | as POST | newest first `[{"command_id", "command", "status": "sent"\|"accepted"\|"rejected"\|"timeout", "detail", "requested_by_name", "sent_ts", "result_ts"}]`; `detail` = the firmware's `state` (accepted) or `error` (rejected); `timeout` = no answer after 15 s (computed on read; a late answer within 30 s still lands) |
| GET | `/me` | any authenticated | `{"user_id", "username", "display_name", "role", "phone", "email", "language", "units": [{"unit_id", "unit_label", "building_id", "floor_label", "kind"}]}`; `units` from resident units, `[]` for staff; `language` `ro`\|`en` (notifications), `ro` until chosen |
| PATCH | `/me` body any of `{"display_name": str (1–60, trimmed), "phone": str, "email": str, "language": "ro"\|"en"}` | any authenticated | same shape. Phone → E.164 (`0722 123 456`, `0040…`, `+40…` → `+40722123456`; other `+…` E.164 kept), `""` clears; email needs one `@` and a dotted domain (≤ 254), `""` clears; `null`, `username`, `role` or other fields → 422. Audited `account_updated` with the changed field names only |
| POST | `/me/household/invites` body `{"unit_id": str, "care_profile_id": str\|null}` | resident | 201 `{"id", "code", "url", "app_url", "unit_id", "unit_label", "care_profile_id", "expires_ts"}` (the only time `code` is shown); 404 not the caller's residential unit / not their non-self profile in it, 422 an `is_self` profile, 409 five pending for the unit |
| GET | `/me/household/invites` | resident | caller's pending invites `[{"id", "unit_id", "unit_label", "care_profile_id", "care_profile_name", "created_ts", "expires_ts"}]` (no code) |
| DELETE | `/me/household/invites/{id}` | resident (inviter) | 204 revoke; 404 otherwise (incl. used / revoked) |
| GET | `/household/invites/{code}` | any authenticated | `{"building_name", "unit_label", "floor_label", "inviter_name", "has_care_profile", "care_profile_name", "expires_ts"}`; unknown / expired / used / revoked → the same 404; counts toward the attempt ceiling |
| POST | `/household/invites/{code}/accept` body `{"take_over_care_profile": bool, "consent": bool}` | resident only (staff incl. admin → 403) | `{"unit_id", "unit_label", "building_id", "care_profile_id": str\|null}`; 409 own invite, 409 take-over while having an `is_self` profile (invite not consumed), 422 take-over without `consent: true`; counts toward the ceiling |
| GET | `/me/household` | resident | `[{"unit_id", "unit_label", "members": [{"user_id", "display_name", "is_me", "since"}]}]` for the caller's residential units (`since`: joined by invite, else `null`) |
| DELETE | `/me/household/{unit_id}` | resident | 204: leave the unit (own membership, own care profiles there and own pending invites for it); 404 not a member |
| GET | `/me/care-profiles` | resident | `CareProfileOut[]` — the caller's own profiles only |
| GET | `/admin/users?building_id=` | system_admin, hoa_manager | `[{"user_id", "username", "display_name", "role", "phone", "email", "active", "units": [{"unit_id", "unit_label"}]}]` (residents by unit, staff by building assignment) |
| POST | `/admin/users` body `{"username", "display_name", "role", "phone"?, "email"?, "unit_ids"?}` | system_admin; hoa_manager (role `resident` only, else 403) | 201 same shape; username `^[a-z0-9._-]{3,32}$` (409 taken), phone/email as `/me`; `unit_ids` residential units in scope (404 / 422), residents only |
| PATCH | `/admin/users/{id}` any of `{"display_name", "role", "phone", "email", "unit_ids", "active"}` | system_admin; hoa_manager (residents of their buildings) | same shape; `unit_ids` replaces the set; staff roles need `unit_ids: []`; `active: false` → `/auth/token` answers 401 `account disabled` (already issued tokens run until they expire); deactivating yourself → 409 |
| GET / POST | `/admin/buildings/{id}/floors` (POST `{"label", "level"}`) | system_admin, hoa_manager | `[{"floor_id", "label", "level"}]` / 201 one |
| GET / POST | `/admin/buildings/{id}/units` (POST `{"label", "floor_id", "kind": "residential"\|"common"}`) | system_admin, hoa_manager | `[{"unit_id", "label", "floor_id", "floor_label", "kind", "residents"}]` / 201 one |
| PATCH | `/admin/units/{id}` `{"label"?, "kind"?}` | system_admin, hoa_manager | unit item; 409 making a unit with residents `common` |
| GET / POST | `/admin/buildings/{id}/zones` (POST `{"label", "kind", "unit_id", "pos_x", "pos_y"}`, floor taken from the unit) | system_admin, hoa_manager | `[{"zone_id", "label", "kind", "unit_id", "unit_label", "floor_id", "floor_label", "pos_x", "pos_y", "nodes": [{"node_id", "name", "kind", "online", "status"}]}]` / 201 one |
| PATCH / DELETE | `/admin/zones/{id}` (PATCH any of `{"label", "kind", "unit_id", "pos_x", "pos_y"}`) | system_admin, hoa_manager | zone item (devices in it follow a new unit) / 204; 409 while nodes or devices are assigned |
| DELETE | `/admin/nodes/{node_id}` | system_admin, hoa_manager (their buildings) | 204: removes an **offline** node, its logical devices, its command history and its firmware data (push target, versions, pushes) (409 `node online`); raw snapshots and readings stay (incident evidence, pruned by retention), so the same base topic re-registers as usual and sees that earlier history. Audited `admin_node_deleted` |
| POST | `/me/care-profiles` body `CareProfileIn` | resident | 201 `CareProfileOut`; 404 unit not one of the caller's residential units, 409 second `is_self`, 422 invalid (see below) |
| PUT | `/me/care-profiles/{id}` body `CareProfileIn` | resident (owner) | `CareProfileOut`; 404 not the owner's |
| DELETE | `/me/care-profiles/{id}` | resident (owner) | 204; hard delete with its care check-ins (works without `CANARY_CARE_KEY`) |
| POST | `/incidents/{id}/care-checkin` body `{"care_profile_id": str, "status": "safe_outside"\|"safe_inside"\|"needs_help"}` | resident (owner, own building) | `{"ok": true}`; 404 unknown/other building/not the owner's, 409 incident not open; WS `care_checkin` |
| GET | `/incidents/{id}/roster` | hoa_manager, dispatcher_external, system_admin | adds `priority: PriorityPersonOut[]` + `priority_awaiting` (open incidents only, else `[]`/`0`) |
| GET | `/incidents/{id}/accounting` | hoa_manager, dispatcher_external, system_admin | adds `priority_awaiting` (a count only) |
| GET | `/incidents/{id}/escalations` | hoa_manager, dispatcher_external, system_admin | `[{"event_id", "state", "attempts", "last_status": int\|null, "last_error": str\|null, "delivered": bool, "ts"}]` — webhook events, oldest first |
| GET | `/incidents/{id}/triangulation/history` | hoa_manager, dispatcher_external, system_admin | `{"incident_id", "snapshots": [{"ts", "source_zone_id", "source_x", "source_y", "confidence", "method", "n_contributors", "airflow_applied", "contributors": [{"device_id", "zone_id", "value", "weight"}]}]}` — every distinct estimate, oldest first, ≤ 500 (evenly thinned, first and last kept); pruned after `CANARY_RETENTION_DAYS` |
| GET | `/buildings/{id}/zones` | any authenticated (resident: own building) | `ZoneOut[]`, now also `unit_label` and `floor_label` (e.g. `Ap. 12`, `Etaj 3`) |

**Language:** generated REST text (`label`, `value`, `detail`, `headline`, `advice`, incident titles) is
Romanian when `Accept-Language` starts with `ro`, else English; codes never change, WebSocket events stay English.
Stored notifications (resident `push`, manager `web_push`) are written in each recipient's `/me` `language`
(default `ro`), whatever the triggering request's language; external-integration rows stay English.

**Dispatcher presence privacy:** `dispatcher_external` never gets raw presence history (`presence.*` history
fields → 403; their default fields leave it out) nor the raw `presence` object in `/buildings/{id}/nodes`, and
gets `radar_presence` / `wifi_presence` readings only while an incident is open in that building. Aggregates
(`/occupancy`, accounting, zone `occupied`) stay available. hoa_manager / system_admin are unchanged.

**Admin scope:** system_admin manages everything; an hoa_manager only the buildings assigned to them in
`staff_buildings` (the seed assigns `mihai` → `bld_007`; a manager with no assignment manages every building,
for older single-building hubs) and only `resident` accounts; other roles get 403, out-of-scope ids 404. Every
admin change is audited `admin_<thing>_<created|updated|deleted>` with the changed field names only. Zone
kinds: `kitchen`, `living_room`, `bedroom`, `bathroom`, `hallway`, `stairwell`, `boiler`, `other`. Device
commands are published only to the hub's own MQTT broker and audited `device_command`.

**Resident scope:** a resident only reaches buildings they have a unit in: `GET /buildings` lists only those;
another building's `/buildings/{id}/*`, `/incidents/{id}[/events|/checkin]` → 404; the WebSocket closes with 1008.
`/buildings/{id}/readings` gives residents hazard readings only (never `radar_presence` / `wifi_presence`).

**Care profiles (health data).** Optional, so people who cannot evacuate alone are prioritized
when they do not respond during an incident (GDPR art. 9: explicit consent, minimal data).
- *Data:* `display_name` (1–60), `needs` from fixed codes `reduced_mobility`, `wheelchair`,
  `bedridden`, `hearing_impaired`, `visually_impaired`, `medical_device`, `young_child`, `pet`,
  optional `note` (≤ 280; no diagnoses or medication). At least one need or a note.
- *Consent:* every create/update needs `"consent": true` (a JSON boolean; `1`/`"true"` → 422)
  and sets `consent_ts`. A resident creates profiles for themselves (`is_self`, at most one) and
  for household members without the app, in their own residential units only.
- *Who sees what, when:* the owner manages them via `/me/care-profiles` (not even a co-resident
  of the same flat sees them). Managers and dispatchers see them **only** in
  `/incidents/{id}/roster` `priority` while the incident is open (detection … evacuation); never
  otherwise, there is no list endpoint for staff. `accounting` carries just `priority_awaiting`.
  Status = latest care check-in or, for `is_self`, the person's own `/checkin`; else `unknown`.
  Sorted `needs_help`, `no_response`, `unknown`, `safe_inside`, `safe_outside`, then unit;
  `priority_awaiting` = everyone not safe. The WebSocket `care_checkin` event carries ids and
  status only. The escalation webhook (below) gets per person only `unit_label`, `floor_label`,
  `needs` codes and `status`: never names, notes or phones.
- *Deletion:* `DELETE` withdraws consent: the profile and its check-ins are hard-deleted.
- *Audit:* `care_profile_created|updated|deleted` (actor user id, target profile id) and
  `care_profile_view` on every roster read that returns priority people (`identity_unlock`,
  `detail: {"count": n}`); entries never contain names, needs or notes.
- *Encryption:* name, needs and note are Fernet-encrypted at rest with `CANARY_CARE_KEY`
  (`scripts/pi_setup.sh` generates it). Without a valid key the care endpoints answer 503 and the
  roster still lists priority people by unit and contact, without details. Keep the key: losing
  or changing it makes stored profiles unreadable.

`CareProfileIn`: `{"unit_id": str, "display_name": str, "is_self": bool, "needs": [code], "note": str|null, "consent": true}`.
`CareProfileOut`: `{"id", "unit_id", "unit_label", "display_name", "is_self", "needs", "note", "consent_ts", "updated_ts"}`.
`PriorityPersonOut`: `{"care_profile_id", "display_name", "unit_id", "unit_label", "floor_label", "needs", "note", "status", "status_ts", "contact_name", "contact_phone"}` (contact = the profile owner).

**Household invites.** A resident invites someone who has (or will get) their own account to their
flat with a link: `url` = `CANARY_PUBLIC_URL/join/<code>`, `app_url` = `canary://join/<code>`. The code
(`secrets.token_urlsafe(16)`) is returned once; the hub stores only its SHA-256. Invites are single use,
expire after 72 h, at most 5 pending per unit; unknown, expired, used and revoked codes give the same 404.
Accepting adds the invitee to the unit (an existing member just consumes the invite). With
`take_over_care_profile` + `consent: true` and a care profile on the invite, the invitee becomes its owner
and person (`is_self`, new `consent_ts`); if they already have an `is_self` profile → 409 and the invite
stays valid. The preview shows the profile's name only, never needs or notes. Ceiling: 20 preview +
accept calls per user per rolling hour (stored in `household_invite_attempts`), then 429. Audit
`household_invite_created|revoked|accepted`, `household_left`, `care_profile_transferred` (ids only:
never the code, names, needs or notes). There is no signup: `/auth/token` knows only existing users.

**Escalation webhook (ARC / 112 partner).** With `CANARY_ESCALATION_URL` set, every transition into
`escalation`, `evacuation` or `resolution` POSTs one event after the transition commits (unset: no
webhook, notification rows only, as before). Headers: `Content-Type: application/json`,
`X-Canary-Event: <event_id>` (unchanged on retries: idempotency key), `X-Canary-Timestamp: <unix s>`
(per attempt), `X-Canary-Signature: sha256=<hex HMAC-SHA256(CANARY_ESCALATION_SECRET, timestamp + "." + raw body)>`.
Receivers must check the signature and a ±5 min timestamp window (`simulator/arc_receiver.py` does).
Delivery runs in the background and never blocks or breaks the incident: 5 s timeout, up to 4 attempts
(0 s, 5 s, 30 s, 120 s), any 2xx is delivered, redirects are not followed. Each attempt is a row in
`escalation_deliveries` (listed by `/incidents/{id}/escalations`); the outcome is audited
`escalation_sent` / `escalation_failed` (state, attempts, status code; no payload). Retries survive a
restart: each event sits in `escalation_outbox` (original body, Fernet-sealed with `CANARY_CARE_KEY`, cleared
once settled); at startup pending events younger than 30 min resume with the same `event_id` and body, older
ones become `expired` (audit `escalation_expired`). Body (`canary.escalation.v1`; no names, notes or phones):
```json
{"schema": "canary.escalation.v1", "event_id": "uuid", "sent_ts": "2026-10-10T12:00:00Z",
 "building": {"id": "bld_007", "name": "Bloc A1", "address": "Str. Exemplu 12, Bucuresti"},
 "incident": {"id": "…", "state": "evacuation", "hazard_type": "combustible_gas", "severity": "critical",
              "opened_ts": "…Z", "primary_zone_id": "zone_kitchen", "primary_zone_label": "Bucătărie",
              "est_source_zone_id": "zone_kitchen", "est_source_zone_label": "Bucătărie",
              "triangulation_confidence": 0.7, "signature_verdict": "gas_leak"},
 "accounting": {"occupancy_total": 3.0, "accounted": 1, "unaccounted": 2, "needs_help": 0, "priority_awaiting": 1},
 "priority": [{"unit_label": "Ap. 12", "floor_label": "Etaj 3", "needs": ["wheelchair"], "status": "unknown"}]}
```
`signature_verdict` (latest hazard-signature label) and the zone labels are `null` when unknown; `priority`
is `[]` once the incident is no longer open (e.g. on `resolution`).

Timestamps (`*_ts`, `ts`) are timezone-aware UTC with a `Z` suffix
(`2026-09-23T12:00:00Z`), on SQLite as well as Postgres. Device data is stamped on
receipt by the hub (§1).

**Receive time and backlog:** the MQTT client stamps every message when it arrives; `last_seen_ts`, the
raw snapshot / reading `ts` and command-result matching (and its 15 s timeout) use that stamp, so a
processing backlog never ages a node or turns a prompt device answer into `timeout`. `GET /health` reports
`"ingest": {"connected": bool, "queue": <messages waiting>, "lag_s": <oldest one's wait>}`.

`BuildingSummary`:
```json
{
  "building_id": "bld_007", "generated_ts": "2026-09-23T12:00:00Z",
  "status": "ok", "headline": "All clear",
  "nodes_total": 2, "nodes_online": 2, "active_incidents": 0,
  "zones": [
    {"zone_id": "zone_kitchen", "zone_label": "Bucătărie", "status": "ok", "occupied": true,
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
For residents `zones`, `nodes_total`, `nodes_online` and, with no open incident, `status`/`headline` cover only their own unit's and common zones (what history allows); while any incident is open in the building, `status`, `headline` and `active_incidents` are whole-building.

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
`minutes` 1–10080 (default 60), at most 20 fields. Fields are dotted paths into the raw document;
booleans become 0/1, missing → `null`. A measurement is `null` (a gap, never a stale value) when its
channel is untrustworthy in that document: `state` `warmup`/`fault`/`uninitialized`, `valid: false` or
`initialized: false`; thresholds (`warn_*`, `danger_*`, `*_threshold`) and the flags themselves stay readable.
Points ascending, ≤ 360: a window with up to 360 snapshots returns them as they are; a longer one is split
into 360 equal time buckets, one point per non-empty bucket with `ts` = its newest sample. Bucket value:
**MAX** for `co.*`, `gas.*`, `particulate.*`, `sensor.adc`, `sensor.*_threshold`, `leak_latched`,
`presence.detected` (short spikes survive); **MEAN** rounded to 0.1 for any other number (e.g. `climate.*`,
`wifi.rssi`); the newest value for text. Nulls are ignored; an all-null bucket is `null`.
Default fields — air: `co.ppm`, `gas.adc`, `particulate.pm1_0`,
`particulate.pm2_5`, `particulate.pm10`, `climate.temperature_c`,
`climate.humidity_percent`, `presence.detected`; water: `sensor.adc`, `leak_latched`.
**Residents:** only nodes in a zone of their own unit or of a common unit (`Unit.kind = common`: hallway,
boiler room) of their building, else 404. Fields: the defaults minus `presence.*` (also their defaults) plus the
thresholds `co.warn_ppm`, `co.danger_ppm`, `gas.warn_adc`, `gas.danger_adc`, `particulate.warn_pm2_5`,
`particulate.danger_pm2_5`, `particulate.warn_pm10`, `particulate.danger_pm10` / `sensor.wet_threshold`,
`sensor.dry_threshold`; any other field → 400.

### Firmware (`app/firmware.py`, `app/api/firmware.py`)

The hub pushes a firmware image to a node through the node's own HTTP update
endpoint (`POST http://<device>/api/ota`, firmware README "Web OTA"), the same way
the device's `/update` page does: multipart field `firmware`, a `.bin` file name,
`Authorization: Bearer <device API token>`. The device keeps its hazard alarm running
while it flashes, answers `{"ok":true,"rebooting":true}` and reboots; its first live
status document after the reboot (uptime reset) confirms the push with the version it
now reports. One push runs at a time per hub process.

The device address and API token are **pinned by staff**, never taken from MQTT unchecked:
the broker has no ACLs, so a forged status document could otherwise point the hub, and
the token, anywhere. The token is Fernet-encrypted under `CANARY_CARE_KEY` (unset → 503)
and never returned. Every status document's `device.firmware` is tracked: the first
document with a new value adds a version history row.

Roles: reads for system_admin, hoa_manager and technician (their buildings); pinning and
pushing for system_admin and technician. Out-of-scope ids answer 404.

| Method | Path | Result |
| --- | --- | --- |
| GET | `/admin/buildings/{building_id}/firmware` | every node: `{"node_id", "name", "kind", "zone_id", "online", "firmware", "reported_ip", "address", "token_set", "blocked", "last_update"}`. `reported_ip` = `wifi.ip` of the latest document (a suggestion); `address` = the pinned one; `blocked` = why a push would be refused now (`offline`, `no_target`, `busy`, `ota_active`) or null |
| GET | `/admin/nodes/{node_id}/firmware` | the same plus `history` (`[{"firmware", "ts"}]`, newest first, from the first document that reported each version) and `updates` (last 20 pushes) |
| PUT | `/admin/nodes/{node_id}/ota-target` body `{"address": "192.168.1.40" or "ip:port", "token": "<12-64 printable chars>"}` | the node's firmware entry. `token` may be left out to keep the stored one (e.g. to follow a new DHCP address); required for a new target (422). Audited `ota_target_set` (field names only) |
| DELETE | `/admin/nodes/{node_id}/ota-target` | 204; audited `ota_target_cleared` |
| POST | `/admin/nodes/{node_id}/firmware` multipart field `firmware` (the `<sketch>.ino.bin`) | 202 push `{"update_id", "node_id", "filename", "size", "sha256", "firmware_before", "firmware_after", "status", "detail", "requested_by_name", "created_ts", "finished_ts"}`. 413 over 4 MiB; 422 not an ESP32 application image for the node's chip (air ESP32-S3, water ESP32-C3; merged, bootloader and partition images are refused); 409 with `detail` = the `blocked` reason. Audited `firmware_push` with the image's sha256 |

Push `status`: `queued` → `uploading` → `flashed` (the device took the image and reboots) →
`confirmed` (it came back; `firmware_after` = the version it reports), or `failed` with
`detail` = the device's error token (`unauthorized`: wrong token; `ota_active`;
`ota_failed: <message>`), `no_target`, `hub_error` or a network error. `timeout` is computed
on read: queued/uploading for 15 min, or flashed with no reboot seen within 5 min (a reboot
within 30 min still confirms it).

## 5. WebSocket (`/api/v1/ws/incidents?building_id=&token=`)

Existing `incident` and `checkin` events are unchanged. New event after every
processed hardware status/availability message (analysis only, no raw values):

```json
{"type": "node", "building_id": "bld_007", "node_id": "canary", "kind": "air",
 "zone_id": "zone_kitchen", "online": true, "status": "ok", "ts": "2026-09-23T12:00:00Z"}
```

Clients refetch `summary` (and, on the dashboard, `nodes`/`history`) on `node`
events, throttled; clients must ignore unknown event types.

A firmware push (§4, Firmware) sends an event on every status change:

```json
{"type": "firmware_update", "building_id": "bld_007", "node_id": "canary", "update_id": "…",
 "status": "flashed", "detail": null, "firmware_after": null, "ts": "2026-10-23T12:00:00Z"}
``` (The `ts` of `incident`
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
| `CANARY_PUBLIC_URL` | `http://localhost` | base of shareable links (household invites: `/join/<code>`) |
| `CANARY_ESCALATION_URL` | unset | escalation webhook target (http/https); unset → no webhook |
| `CANARY_ESCALATION_SECRET` | unset | HMAC key signing the webhook; written to `.env` by `scripts/pi_setup.sh`; share it with the partner |
| `CANARY_CARE_KEY` | unset | Fernet key encrypting care profiles and the device API tokens of firmware push targets; written to `.env` by `scripts/pi_setup.sh`. Unset → care and firmware-target endpoints 503 |
| `CANARY_RETENTION_DAYS` | `14` | hourly, in batches of 2000 rows, delete `node_status`, `sensor_readings`, `occupancy_estimates`, `signature_assessments` and `triangulation_snapshots` rows older than this; `0` disables. Incidents, events, check-ins, escalation deliveries and the audit log are never pruned |
| `CANARY_LLM_URL` | unset | hailo-ollama on a Raspberry Pi AI HAT+ 2 (e.g. `http://host.docker.internal:11434`) for incident briefs; unset → template briefs |
| `CANARY_LLM_MODEL` | `qwen2.5-instruct:1.5b` | model hailo-ollama runs for the briefs |
| `CANARY_CLUSTER_MODE` | `single` | `single`: one Pi runs everything. `triple`: three redundant Pis (RUNME.md section 3) |
| `CANARY_NODE_NAME` | `hub` | triple: this Pi's home role, `processing`, `web` or `ai` (written per Pi by `scripts/pi_setup.sh`) |
| `CANARY_PROCESSING_IP` / `_WEB_IP` / `_AI_IP` | unset | triple: the three Pis' LAN addresses |
| `CANARY_VIP` | unset | triple: the floating hub address inside the cluster (processing Pi's broker connection); sensors, dashboard and app use `canary-hub.local`, announced at the VIP holder's DHCP address |
| `CANARY_CLUSTER_SECRET` | unset | triple: key of the node-to-node calls (`X-Canary-Cluster-Key` on `/internal/...`, never proxied by nginx) |
| `CANARY_VRRP_STATE_FILE` | `/run/canary/vrrp_state` | triple: where keepalived writes whether this Pi holds the hub address |

Under docker compose, `docker-compose.yml` fixes the MQTT connection (enabled, broker
`mosquitto:1883` or `CANARY_MQTT_HOST`, user `hub`; the password comes from `.env`) and uses
SQLite at `/data/canary.db` unless `.env` sets `CANARY_DATABASE_URL`. Every other setting can be
added to `.env`. In triple mode `scripts/pi_setup.sh --cluster` writes the cluster settings,
`CANARY_MQTT_HOST=<VIP>` and the shared Postgres URL (`?host=<p>:5432&host=<w>:5432&host=<a>:5432&target_session_attrs=read-write`).

### Three-Pi mode (`CANARY_CLUSTER_MODE=triple`)

| Work | Runs on | When that Pi is down |
| --- | --- | --- |
| Hub address (VIP, and `canary-hub.local` + `_canary-hub._tcp` from the `announcer`): broker for the sensors, dashboard, API for the app | the `web` Pi (keepalived) | moves to `processing`, then `ai` (a few seconds) |
| Relay: live device messages from a Pi's broker to the VIP's, commands back (`cluster/relay`) | every Pi without the VIP | sensors on that Pi's broker reconnect to the VIP |
| Processing: MQTT subscription, detection, incidents, notifications, retention | holder of the `processing` lease (`cluster_leases`, 15 s, renewed every 2 s) | `web`, then `ai`, after the lease expires; back home 30 s after the Pi returns |
| AI: triangulation, signature shadow model, incident brief (`POST /internal/ai/{task}`) | the `ai` Pi (AI HAT+ 2 for the brief) | computed by the caller itself (CPU; briefs fall back to the template) |
| Database | Patroni Postgres primary (synchronous replica on another Pi) | a replica is promoted |

Safety rules (detection, the incident state machine, false-alarm and signature rules) always run
on the processing Pi and never wait on another one. Every Pi serves the API and forwards its
WebSocket events to the others (`POST /internal/cluster/broadcast`). Because another Pi's broker
may hold old retained copies, a retained `status` of a known node and a retained `online` are
ignored in this mode (the next live document follows within 15 s for air, 60 s for water); a
retained `offline` (last will) still applies. `GET /api/v1/cluster` (hoa_manager, technician,
system_admin) shows which Pi runs what.

# DEBUG — Canary (agent test & troubleshooting guide)

Deterministic, non-interactive checks an AI agent (or human) can run to verify and
debug each layer. Every check lists the **command**, **expected result**, and the
**exit signal** to branch on. Run from `RPISoftware/` unless noted. Overview:
[`README.md`](./README.md). How to run everything: [`RUNME.md`](./RUNME.md). MQTT/API
contract: [`docs/HARDWARE.md`](./docs/HARDWARE.md).

---

## TL;DR — agent test checklist

| # | Layer | Command | Pass signal |
|---|-------|---------|-------------|
| 1 | Backend tests + web build + infra static checks | `bash scripts/smoke.sh` | prints `SMOKE: PASS`, exit 0 |
| 2 | Backend runtime | curl `/health` (see §2) | `{"status":"ok"}` |
| 3 | Web build | `cd web && npm run build` | `✓ built`, exit 0 |
| 4 | Mobile analyze | `bash scripts/mobile_check.sh` | `No issues found!`, exit 0 |
| 5 | E2E | §5 below | incident reaches `evacuation`, unaccounted drops |
| 6 | Hub stack (Docker) | `docker compose up -d --build --wait` | exit 0; `docker compose ps` shows 3 × `(healthy)` |
| 7 | Hardware path | `docker compose --profile sim run --rm hw-sim --scenario smoke --fast --exit` | exit 0; the summary goes `ok` → `attention` → `danger` (§7.2) |

Checks 1–3 need no Docker/Flutter. Check 4 needs Flutter. Check 5 needs the backend
running. Checks 6–7 need Docker and `scripts/pi_setup.sh` run once.

---

## 1. Backend — unit/integration tests

```bash
cd backend
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev]" -q
python -m pytest -q
```
- **Expect:** `95 passed`, no failures (warnings about short JWT key are benign — test secret).
- **Exit 0** = pass. Non-zero → read the failing test name; pure-logic tests
  (`test_detection`, `test_state_machine`, `test_triangulation`, `test_false_alarm`,
  `test_hardware_translation`, `test_environment_analysis`) isolate engine bugs;
  `*_flow`/`*_endpoint`/`test_hardware_ingest` isolate wiring/DB bugs.
- Run one file: `python -m pytest tests/test_false_alarm.py -q`
- Verbose on failure: `python -m pytest -x -vv`

### Pure-logic only (no deps installed — stdlib import check)
```bash
cd backend && PYTHONPATH=. python3 -c "
from app.detection.engine import evaluate
from app.incidents.state_machine import forward_chain
print('pure import OK')"
```

---

## 2. Backend — runtime smoke (SQLite, no broker)

```bash
cd backend && . .venv/bin/activate
export CANARY_DATABASE_URL="sqlite+aiosqlite:///./dbg.db" CANARY_MQTT_ENABLED=false \
       CANARY_JWT_SECRET="debug-secret-key-at-least-32-bytes-long"
uvicorn app.main:app --port 8000 &   # or run foreground in another shell
sleep 2
curl -s localhost:8000/health
TOKEN=$(curl -s localhost:8000/api/v1/auth/token -H 'content-type: application/json' \
  -d '{"username":"mihai"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
# critical gas -> evacuation + triangulation
curl -s localhost:8000/api/v1/telemetry -H 'content-type: application/json' -d '{
 "schema":"canary.telemetry.v1","device_id":"dev_gas_kitchen","sensor_type":"combustible_gas",
 "location":{"building_id":"bld_007","floor_id":"flr_03","unit_id":"unit_0312","zone_id":"zone_kitchen"},
 "value":6000,"units":"ppm","edge_state":"alarm","epoch":1,"seq":1}'
ID=$(curl -s "localhost:8000/api/v1/buildings/bld_007/incidents?active=true" \
  -H "Authorization: Bearer $TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
curl -s "localhost:8000/api/v1/incidents/$ID/triangulation" -H "Authorization: Bearer $TOKEN"
curl -s "localhost:8000/api/v1/incidents/$ID/accounting"   -H "Authorization: Bearer $TOKEN"
kill %1; rm -f dbg.db
```
- **Expect:** health ok; telemetry `"incident_state":"evacuation"`; triangulation
  `"source_zone_id":"zone_kitchen"` with `confidence>0`; accounting JSON.

### Schema + seed bootstrap check (MQTT off)
```bash
cd backend && . .venv/bin/activate
CANARY_DATABASE_URL="sqlite+aiosqlite:///./b.db" CANARY_MQTT_ENABLED=false \
CANARY_JWT_SECRET="debug-secret-key-at-least-32-bytes-long" \
python -c "import asyncio; from app.db import init_db; from app.seed import seed_if_empty; \
asyncio.run(init_db()); asyncio.run(seed_if_empty()); print('boot OK')"
rm -f b.db
```
- **Expect:** `boot OK` (tables created + demo building seeded, no exceptions).
- pytest §1 + curl §2 already exercise the full lifespan via the ASGI test client.

---

## 3. Web dashboard

```bash
cd web
[ -d node_modules ] || npm install
npm run build          # tsc --noEmit && vite build
```
- **Expect:** no TS errors, `✓ built in …`. Exit 0 = pass.
- Type errors print as `path(line,col): error TSxxxx`. Fix the type; types live in
  `src/api/types.ts` and must match backend JSON (snake_case).
- The `chunks larger than 500 kB` note is a **warning** (Recharts), not a failure.
- Runtime check: `npm run dev`, open `http://localhost:5173`, DevTools console should be
  clean; network calls hit `VITE_API_BASE`. A blank screen → check `.env` / CORS (§6).
- In Docker the same build runs with an empty `VITE_API_BASE` (same origin; nginx proxies
  `/api`), so a `web` image build failure is usually this same `npm run build` failing.
- Console errors **only while the backend or nginx restarts** are expected and harmless:
  `WebSocket connection to 'ws://…/api/v1/ws/incidents?…' failed` (one per reconnect
  attempt, backing off 1 s → 15 s), `Failed to load resource: … 502 (Bad Gateway)`
  (backend down behind nginx) and `net::ERR_CONNECTION_REFUSED` (nginx itself down). The
  browser logs these itself; the page recovers on its own (Topbar back to **Live**).
  In normal operation the console stays empty. Anything else (a JS exception, a React
  warning) is a real bug. Note: the failed-WebSocket line shows the JWT from the URL — it
  is your own session's token in your own browser, but don't paste it into bug reports.

---

## 4. Mobile (Flutter) — install, analyze, debug

### 4a. Confirm toolchain
```bash
flutter --version          # 3.22+ stable
flutter doctor -v          # web ✓ required; Android/iOS optional
```
If `flutter` is missing, install it (RUNME §2.5). First invocation downloads the Dart SDK.

### 4b. Resolve + analyze (primary gate — no device needed)
```bash
cd mobile
[ -d web ] || flutter create --platforms=web,android,ios .   # backfill platform dirs
flutter pub get
flutter analyze
flutter test        # widget smoke test + BuildingSummary contract parsing
```
- **Expect:** `No issues found!` (info-level lints OK), then `All tests passed!`. Exit 0 = pass.
- `flutter analyze` is the real compile/type gate for Dart — run it after any edit.

### 4c. Compile / run
```bash
# compile-check for web without a device:
flutter build web --no-tree-shake-icons        # exit 0 = compiles

# interactive debug, no emulator:
flutter run -d chrome --dart-define=CANARY_API=http://localhost:8000
#   hot reload: r   |  restart: R  |  quit: q
```

### Known design notes (so failures are interpretable)
- **Firebase is optional at runtime.** `Config.enableFirebasePush` defaults `false`;
  `Firebase.initializeApp()` is only called when `--dart-define=CANARY_FCM=true`. So the
  app runs/builds with **no** `google-services.json` / `GoogleService-Info.plist`.
- If an **Android** build (`flutter build apk`) fails on the google-services plugin,
  either run `flutterfire configure`, or it indicates the plugin got applied without a
  config — `flutter analyze` / `flutter run -d chrome` do not hit this.
- iOS builds need **full Xcode** (not just CommandLineTools) and the critical-alert
  entitlement for breakthrough alerts.
- Offline check-in queue uses `shared_preferences`; state via Riverpod.

### Common Dart/Flutter errors → fix
| Symptom | Cause | Fix |
|---------|-------|-----|
| `Target of URI doesn't exist: package:...` | dep missing / no `pub get` | add to `pubspec.yaml`, `flutter pub get` |
| `The method 'X' isn't defined` after SDK bump | API moved | check package changelog; `flutter pub upgrade --major-versions` |
| `withOpacity deprecated` | Flutter ≥3.27 | info-only; ignore, or switch to `.withValues` |
| WebSocket never connects | wrong host on emulator | use `10.0.2.2` (Android) not `localhost` |
| Notifications silent in foreground | expected | foreground uses in-app/WS; OS suppresses tray when active |

---

## 5. End-to-end verification (backend running)

```bash
# 1) start backend (Docker or SQLite, RUNME §1 / §2.2)
# 2) drive a hazard
curl -s localhost:8000/api/v1/telemetry -H 'content-type: application/json' -d '{
 "schema":"canary.telemetry.v1","device_id":"dev_gas_kitchen","sensor_type":"combustible_gas",
 "location":{"building_id":"bld_007","floor_id":"flr_03","unit_id":"unit_0312","zone_id":"zone_kitchen"},
 "value":6000,"units":"ppm","edge_state":"alarm","epoch":1,"seq":1}'
```
Verify, in order:
1. response `incident_state:"evacuation"`, `severity:"critical"`
2. `GET /incidents/{id}/events` → ladder `detection → alarm → escalation → evacuation`
3. `GET /incidents/{id}/triangulation` → `source_zone_id:"zone_kitchen"`, `confidence>0`
4. resident check-in drops unaccounted:
   ```bash
   RTOK=$(curl -s localhost:8000/api/v1/auth/token -H 'content-type: application/json' -d '{"username":"ana"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
   curl -s -X POST localhost:8000/api/v1/incidents/$ID/checkin -H "Authorization: Bearer $RTOK" -H 'content-type: application/json' -d '{"status":"safe_outside"}'
   ```
5. false-alarm: lone flat sensor is **held** (not alarmed):
   ```bash
   for s in 1 2 3; do curl -s localhost:8000/api/v1/telemetry -H 'content-type: application/json' -d "{
    \"schema\":\"canary.telemetry.v1\",\"device_id\":\"dev_gas_kitchen\",\"sensor_type\":\"combustible_gas\",
    \"location\":{\"building_id\":\"bld_007\",\"floor_id\":\"flr_03\",\"unit_id\":\"unit_0312\",\"zone_id\":\"zone_kitchen\"},
    \"value\":1050,\"units\":\"ppm\",\"edge_state\":\"normal\",\"epoch\":1,\"seq\":$s}" >/dev/null; done
   # incident state stays "verification", false_alarm_class "likely_benign"
   ```
   (Use a fresh DB for this — a prior critical incident would already be open.)

---

## 6. Troubleshooting (application)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Address already in use :8000` | stale uvicorn (or the Docker backend) | `lsof -ti:8000 \| xargs kill`, or `docker compose stop backend` |
| Dashboard 401 on every call | bad/expired token | re-login; `CANARY_JWT_SECRET` must match the running backend |
| Dashboard CORS error | API base mismatch | backend `cors_origins` defaults `*`; set `VITE_API_BASE` correctly |
| Simulator can't connect | broker down, or no/wrong login | `docker compose up -d mosquitto`; credentials: §8.2. Or use HTTP ingress (RUNME §2.3) |
| `triangulation source = first-detection zone` (not peak) | tz bug regressed | timestamps must be UTC-normalized — see `app/analytics/service.py::_epoch` |
| Incident never alarms on repeated 1-sensor readings | by design | false-alarm hold; needs 2nd sensor/zone or a rising trend (DEBUG §5.5) |
| Incident stays open although every sensor reads normal | by design: only a device that reported the hazard can clear it, with `CANARY_CLEAR_HOLD_SAMPLES` (3) clearing readings in a row | wait for that device's next heartbeats; if it went offline, resolve the incident on the dashboard |
| Device thresholds seem ignored | they failed the sanity check (non-finite, or not `0 < warn < danger`). The firmware refuses such values itself, so suspect another publisher on that base topic | the backend defaults apply by design (docs/HARDWARE.md §2, safety rules); find the publisher with §8.1 |
| Times shifted by the UTC offset in a client | a timestamp without zone read as local time | every REST timestamp must end in `Z` (`UTCDateTime` in `app/models.py`; `test_timestamps_are_utc_aware_on_sqlite`) |
| Postgres only: hardware readings stop after ~25 days of device uptime; backend logs `ingest failed for <node>:<channel>` | database created before `sensor_readings.seq` became 64-bit (no migrations) | `ALTER TABLE sensor_readings ALTER COLUMN seq TYPE bigint;` |
| pytest `InsecureKeyLengthWarning` | short test secret | benign; ignore |

### Where to look
- Backend logs: stdout of uvicorn / `docker compose logs backend`. Dashboard requests
  are also logged by nginx: `docker compose logs web`. The WebSocket JWT (`?token=`)
  is kept out of both: uvicorn prints `token=***`, nginx logs the WebSocket line without
  its query string and records only `crit` errors for that location. Client IPs and
  device names still appear, so review logs before sharing them.
- MQTT: `docker compose logs mosquitto` (connections, auth failures) and a live
  subscription (§8.1).
- DB (SQLite): locally the `*.db` file; in Docker the `canary_backend_data` volume
  (`docker compose cp backend:/data ./db-copy`). Tables `incidents`, `incident_events`,
  `sensor_readings`, plus the hardware tables `nodes` and `node_status` (raw documents).
  Raw documents, readings and occupancy older than `CANARY_RETENTION_DAYS` (14) are
  pruned hourly.
- Test transcripts: `python -m pytest -vv` shows request/response logs (httpx INFO lines).

---

## 7. Hub stack (Docker / Raspberry Pi)

### 7.1 Health
```bash
docker compose ps                    # mosquitto, backend, web: "Up ... (healthy)"
curl -s localhost/health             # through nginx -> {"status":"ok",...}
curl -s localhost:8000/health        # straight to the backend
docker compose logs --tail 50 backend mosquitto web
```

### 7.2 Hardware path end to end (no hardware)
```bash
docker compose --profile sim run --rm hw-sim --scenario smoke --fast --exit &
HUB=http://localhost
TOKEN=$(curl -s $HUB/api/v1/auth/token -H 'content-type: application/json' \
  -d '{"username":"mihai"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
sleep 20; curl -s $HUB/api/v1/buildings/bld_007/summary -H "Authorization: Bearer $TOKEN"
```
- **Expect:** the `canary` (air) and `water-sensor` nodes exist. With `--fast` the
  container start, warm-up and first heartbeat take ~8 s. About 11 s into the run the
  building is `attention` (verification), and from ~18 s it is `danger`
  (`Smoke / particulates ALARM`, AQI 265). The incident stays open after the air clears
  (~37 s): only the air node can clear it, with 3 clearing readings in a row, and
  `--exit` stops it first. Resolve it on the dashboard (without `--exit` it closes a few
  heartbeats later). After the sim exits (~40 s), both nodes show `online: false`
  (their last will).

### 7.3 Common problems
| Symptom | Cause | Fix |
|---|---|---|
| `required variable CANARY_MQTT_PASSWORD is missing a value: run scripts/pi_setup.sh first` | no `.env` | `scripts/pi_setup.sh` |
| mosquitto restarts; log `Error: Unable to open pwfile "/mosquitto/config/passwd"` | password file missing (or unreadable by uid 1883, e.g. copied by hand) | `scripts/pi_setup.sh` (creates it and fixes its owner/mode) |
| mosquitto log `Unable to open config file` (macOS) | checkout outside the folders the Docker VM shares | move the checkout under your home directory (RUNME §2.1) |
| `bind: address already in use` for port 80 | another web server (Pi-hole, lighttpd, ...) | `CANARY_HTTP_PORT=8080` in `.env`, `docker compose up -d` |
| dashboard answers `502 Bad Gateway` on `/api` | backend down or still starting | `docker compose ps`, `docker compose logs backend` |
| dashboard loads, live updates never arrive | WebSocket not reaching the backend | `docker compose logs web` must show `GET /api/v1/ws/incidents ... 101` |
| first `--build` killed / extremely slow on the Pi | not enough RAM for `npm ci` + `vite build` | Pi with 2 GB+ RAM, or add swap (`sudo dphys-swapfile`), then retry |

---

## 8. MQTT troubleshooting

### 8.1 Watch the broker
```bash
# once per broker container start: the hub login into a root-only options file
printf -- '-u hub\n-P %s\n' "$(sed -n 's/^CANARY_MQTT_PASSWORD=//p' .env)" |
  docker compose exec -T mosquitto sh -c 'umask 077 && cat > /tmp/hub.opts'
docker compose exec mosquitto mosquitto_sub -o /tmp/hub.opts -v -t '#'
# with receive time and retain flag (r=1 = replayed retained message):
docker compose exec mosquitto mosquitto_sub -o /tmp/hub.opts -t '#' -F '%I r=%r %t %p'
```
Per base topic you must see `<base>/availability` (`online`/`offline`) and `<base>/status`
(JSON). Air sends a status at least every 15 s, water every 60 s, and both send one on
every state change. A reading that changes without changing a state (CO 3 → 20 ppm,
radar presence) only shows up in the next heartbeat. That is firmware behaviour, not a
lost message.

### 8.2 Authentication failures
Broker log: `Client <client-id> [<ip>:<port>] disconnected: not authorised.` The client
id tells you who it is: sensors connect as `<device-name>-<6 hex chip id>`
(e.g. `canary-1a2b3c`), the backend as `auto-…` with user `hub`.

| Who | Cause | Fix |
|---|---|---|
| a sensor | user/password typed wrong in its portal (the password field is write-only: "leave blank to keep") | re-enter both in the portal; issue a new password with `scripts/pi_setup.sh --rotate <user>` if unsure |
| a sensor | user never created | `scripts/pi_setup.sh <user>` (it reloads a running broker; otherwise `docker compose kill -s SIGHUP mosquitto`) |
| backend / simulators | `CANARY_MQTT_PASSWORD` in `.env` changed but the broker's file was not updated | `scripts/pi_setup.sh`, then `docker compose up -d` |
| anything | anonymous client (no user configured) | every client needs a login: `allow_anonymous false` |

List the broker's users (names only): `docker compose exec mosquitto cut -d: -f1 /mosquitto/config/passwd`.

### 8.3 A sensor sends nothing
1. Ask the device: `curl -s http://<device-ip>/api/status` (unauthenticated) and look at
   `"mqtt":{"enabled":…,"connected":…}`.
   - `enabled:false` → set **MQTT enabled** to `1` in the portal.
   - `connected:false` → wrong host/port, the broker is unreachable (router/VLAN firewall,
     `nc -vz <pi-ip> 1883` from a laptop on the sensor's network), or it is not
     authorised (§8.2).
2. `docker compose logs mosquitto | grep -iE "new client|not authori"`: does it connect at all?
3. Subscribe to `#` (§8.1): it may be publishing under a different base topic than you expect.
4. On the broker but not in the dashboard → `docker compose logs backend | grep -i mqtt`
   (`subscribed to #`?) and compare the status JSON with docs/HARDWARE.md.

### 8.4 Two devices share a base topic
Two devices on the same base topic (typically both left at the default `canary` or
`water-sensor`) overwrite each other's retained `status`/`availability`. The hub sees
**one** node whose `uptime_ms` jumps back and forth (it reads that as constant reboots:
`boot_epoch` keeps climbing) and whose availability flaps. Spot it with the `-F` form of
§8.1 (two different `device.name`/uptime series on one topic) or two client ids for the
same base in the broker log. An air and a water device on one base show up differently:
the hub keeps the kind it registered first and drops the other device's documents
(backend log: `base topics must be unique`). Fix: give each device a unique base topic
in its portal (= its MQTT user, RUNME §1.4), then clear the old topic's retained
messages (§8.6).

### 8.5 Stale retained status
The broker keeps the last retained `status` and `availability` of every base topic,
also across broker restarts (the `canary_mosquitto_data` volume). A sensor that was
renamed, moved to a new base topic or retired leaves its last status and `offline`
behind. Every new subscriber, including the backend after a restart, receives them
again, so the old node reappears as offline. The backend ignores a re-delivered status
with an unchanged `uptime_ms`, and retained messages do not refresh "last seen", so this
is harmless but untidy. Clear it (§8.6).

### 8.6 Clearing a retained message
Publish an empty retained message to the topic:
```bash
docker compose exec mosquitto mosquitto_pub -o /tmp/hub.opts -r -n -t 'old-base/status'
docker compose exec mosquitto mosquitto_pub -o /tmp/hub.opts -r -n -t 'old-base/availability'
```
(`-r -n` = retained, zero-length payload, which deletes the retained message.) A live
device simply re-publishes on its next heartbeat. To drop **all** retained messages:
`docker compose down && docker volume rm canary_mosquitto_data && docker compose up -d`.

Commands (`<base>/valve/set`, `<base>/buzzer/set`) must never be retained: a retained
command is executed again on every reconnect. If one was published with `-r`, clear it
the same way: `mosquitto_pub -o /tmp/hub.opts -r -n -t '<base>/valve/set'`.

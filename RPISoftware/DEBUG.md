# DEBUG — Canary (agent test & troubleshooting guide)

Deterministic, non-interactive checks an AI agent (or human) can run to verify and
debug each layer. Every check lists the **command**, **expected result**, and the
**exit signal** to branch on. Run from the repo root unless noted.

---

## TL;DR — agent test checklist

| # | Layer | Command | Pass signal |
|---|-------|---------|-------------|
| 1 | Backend tests | `bash scripts/smoke.sh` | prints `SMOKE: PASS`, exit 0 |
| 2 | Backend runtime | curl `/health` (see §2) | `{"status":"ok"}` |
| 3 | Web build | `cd web && npm run build` | `✓ built`, exit 0 |
| 4 | Mobile analyze | `bash scripts/mobile_check.sh` | `No issues found!`, exit 0 |
| 5 | E2E | §5 below | incident reaches `evacuation`, unaccounted drops |

Checks 1–3 need no Docker/Flutter. Check 4 needs Flutter. Check 5 needs the backend running.

---

## 1. Backend — unit/integration tests

```bash
cd backend
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev]" -q
python -m pytest -q
```
- **Expect:** `42 passed` (warnings about short JWT key are benign — test secret).
- **Exit 0** = pass. Non-zero → read the failing test name; pure-logic tests
  (`test_detection`, `test_state_machine`, `test_triangulation`, `test_false_alarm`)
  isolate engine bugs; `*_flow`/`*_endpoint` isolate wiring/DB bugs.
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

---

## 4. Mobile (Flutter) — install, analyze, debug

### 4a. Confirm toolchain
```bash
flutter --version          # 3.22+ stable
flutter doctor -v          # web ✓ required; Android/iOS optional
```
If `flutter` is missing, install it (RUNME §4a). First invocation downloads the Dart SDK.

### 4b. Resolve + analyze (primary gate — no device needed)
```bash
cd mobile
[ -d web ] || flutter create --platforms=web,android,ios .   # backfill platform dirs
flutter pub get
flutter analyze
```
- **Expect:** `No issues found!` (info-level lints OK). Exit 0 = pass.
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
# 1) start backend (Docker or SQLite, RUNME §1)
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

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Address already in use :8000` | stale uvicorn | `lsof -ti:8000 \| xargs kill` |
| Dashboard 401 on every call | bad/expired token | re-login; `CANARY_JWT_SECRET` must match the running backend |
| Dashboard CORS error | API base mismatch | backend `cors_origins` defaults `*`; set `VITE_API_BASE` correctly |
| Simulator can't connect | broker down | `docker compose up -d emqx`, or use HTTP ingress (RUNME §2) |
| `triangulation source = first-detection zone` (not peak) | tz bug regressed | timestamps must be UTC-normalized — see `app/analytics/service.py::_epoch` |
| Incident never alarms on repeated 1-sensor readings | by design | false-alarm hold; needs 2nd sensor/zone or a rising trend (DEBUG §5.5) |
| pytest `InsecureKeyLengthWarning` | short test secret | benign; ignore |
| `docker compose` Timescale unhealthy | first-boot init | wait for healthcheck; `docker compose logs timescaledb` |

### Where to look
- Backend logs: stdout of uvicorn / `docker compose logs backend`.
- MQTT: EMQX dashboard `http://localhost:18083` (admin/public).
- DB (SQLite): open the `*.db` file; tables `incidents`, `incident_events`, `sensor_readings`.
- Test transcripts: `python -m pytest -vv` shows request/response logs (httpx INFO lines).

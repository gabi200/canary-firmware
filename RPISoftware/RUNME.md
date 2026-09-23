# RUNME — Canary

How to run every layer of Canary locally. Copy-paste blocks with **expected output**.
For debugging/troubleshooting see [`DEBUG.md`](./DEBUG.md).

```
backend/    FastAPI + detection + incidents + analytics (triangulation, false-alarm) + WS
simulator/  MQTT sensor simulator (canary.telemetry.v1)
web/        React + TS operations dashboard (manager + dispatch)
mobile/     Flutter resident app (alerts, evacuation, check-in)
scripts/    smoke.sh (backend tests + web build), mobile_check.sh (flutter analyze)
```

## Prerequisites

| Tool | Version | Needed for |
|------|---------|-----------|
| Python | 3.12+ | backend, simulator |
| Node | 20+ (22 tested) | web dashboard |
| Docker + Compose | recent | full stack (Timescale + Redis + EMQX) — optional |
| Flutter | 3.22+ (stable) | mobile app |
| Chrome | any | `flutter run -d chrome` (debug mobile without an emulator) |

> No Docker? The backend runs on **SQLite** and the simulator can use the **HTTP**
> telemetry ingress instead of MQTT — see the "no-Docker" notes below.

---

## 0. One-command smoke (no Docker, no Flutter)

Runs backend tests + web typecheck/build. Best first check.

```bash
bash scripts/smoke.sh
```

Expected tail:
```
42 passed
✓ built in ~1.5s
SMOKE: PASS
```

---

## 1. Backend

### Option A — Docker (full stack: Timescale + Redis + EMQX + API)
```bash
docker compose up -d --build
curl -s localhost:8000/health        # {"status":"ok",...}
open http://localhost:8000/docs      # OpenAPI
```

### Option B — Local, SQLite, no broker (fast)
```bash
cd backend
python3 -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"
export CANARY_DATABASE_URL="sqlite+aiosqlite:///./canary.db"
export CANARY_MQTT_ENABLED=false
export CANARY_JWT_SECRET="local-dev-secret-change-me-please-1234"
uvicorn app.main:app --reload --port 8000
# http://localhost:8000/docs ; schema + demo data auto-created on startup
```

---

## 2. Drive sensors

### With Docker (MQTT)
```bash
docker compose run --rm simulator --scenario gas_leak
#   scenarios: normal | gas_leak | co | water_leak | presence | all
```

### Without Docker (HTTP ingress — same pipeline as MQTT)
```bash
# critical kitchen gas -> evacuation
curl -s localhost:8000/api/v1/telemetry -H 'content-type: application/json' -d '{
 "schema":"canary.telemetry.v1","device_id":"dev_gas_kitchen","sensor_type":"combustible_gas",
 "location":{"building_id":"bld_007","floor_id":"flr_03","unit_id":"unit_0312","zone_id":"zone_kitchen"},
 "value":6000,"units":"ppm","edge_state":"alarm","epoch":1,"seq":1}'
# -> {"status":"accepted","incident_state":"evacuation",...}
```

---

## 3. Web dashboard

```bash
cd web
npm install
echo "VITE_API_BASE=http://localhost:8000" > .env
npm run dev            # http://localhost:5173
```
Sign in as **`mihai`** (manager) or **`dispecer`** (dispatcher), building **`bld_007`**.
Trigger a hazard (section 2) → incident appears live; Dispatch shows triangulated source,
occupancy/unaccounted, signal assessment.

Build/typecheck only: `npm run build`.

---

## 4. Mobile (Flutter)

### 4a. Install Flutter (pick one; ~1GB first download)
```bash
# macOS Homebrew
brew install --cask flutter

# OR git (any OS)
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"      # add to your shell profile

flutter --version
flutter doctor                              # web + the toolchains you have
```

### 4b. Generate platform folders + deps
`android/` `ios/` `web/` are not committed. Backfill them (keeps `lib/` + `pubspec.yaml`):
```bash
cd mobile
flutter create --platforms=web,android,ios .
flutter pub get
```

### 4c. Run / debug
```bash
flutter analyze                             # static analysis — primary gate (expect: no issues)
flutter run -d chrome \
  --dart-define=CANARY_API=http://localhost:8000     # no emulator needed

# Android emulator / device:
flutter run --dart-define=CANARY_API=http://10.0.2.2:8000   # 10.0.2.2 = host from emulator
```
Log in as **`ana`** (resident), building **`bld_007`**. Trigger a hazard (section 2) →
the app receives the WebSocket event → full-screen alarm → evacuation guidance → check-in
(drops the unaccounted count on the dashboard).

> Remote push (FCM) is **off by default** so the app runs with no Firebase config. To
> enable, run `flutterfire configure` and pass `--dart-define=CANARY_FCM=true`. iOS
> critical alerts need Apple's entitlement and full Xcode (only CommandLineTools is
> required for analyze / web).

Quick mobile gate (after Flutter is installed):
```bash
bash scripts/mobile_check.sh    # flutter create (if needed) + pub get + analyze
```

---

## Demo accounts (seeded; dev token by username, no password)

| username | role | view |
|----------|------|------|
| `ana` | resident | mobile app |
| `mihai` | hoa_manager | dashboard /manager |
| `dispecer` | dispatcher_external | dashboard /dispatch |
| `admin` | system_admin | everything |

## End-to-end demo (all layers)
```bash
docker compose up -d --build                 # 1. backend
cd web && npm install && npm run dev &       # 2. dashboard (mihai)
cd mobile && flutter run -d chrome --dart-define=CANARY_API=http://localhost:8000 &  # 3. app (ana)
docker compose run --rm simulator --scenario gas_leak   # 4. trigger
# watch: incident opens -> triangulated source on dashboard -> app alarm -> check-in -> unaccounted drops
```

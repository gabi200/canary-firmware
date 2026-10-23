# Canary — Operations Dashboard (React)

Role-based web console for the Canary safety platform, built from ARCHITECTURE.md
**section C** (its "As built" note lists what differs from the plan) — three views, live
over WebSocket:

- **Manager / HOA** (`/manager`) — building floor plan with live sensor status,
  device health, a compact **Environment** summary (building status + one line per
  hardware node), environmental trends (gas/CO, one chart per unit), active incidents
  with actions, and a demo "simulate gas leak" trigger. While a three-Pi hub runs
  degraded, a warning line on top links to Administration → Hub.
- **Dispatch / emergency services** (`/dispatch`) — incident-centric: hazard source on
  the floor plan, live occupancy + **unaccounted-occupant count**, last-known occupied
  zones, evacuation progress, and the incident timeline + actions. **Incident brief**:
  a short text summary generated on demand (`GET /incidents/{id}/brief`, never polled):
  the LLM on the AI HAT+ 2 (up to a minute) or a template without one.
- **Administration → Firmware** (`/admin/firmware`; managers read, technicians and the
  system admin act) — the firmware version of every sensor in the scope, each one's version
  history and dashboard pushes, its pinned device address and API token ("Device access";
  the token is write-only), and "Update firmware": pick the `.bin`, the page checks the chip
  and image type before upload, lists the matching sensors and queues the push on each
  selected one. Progress (`firmware_update` WebSocket events): waiting → sending →
  installed, restarting → done (the version the sensor reports after its reboot) or failed
  with the device's reason ([`docs/HARDWARE.md`](../docs/HARDWARE.md) §4, Firmware).
- **Administration → Hub** (`/admin/hub`; managers, technicians, system admin) — the
  hub's Raspberry Pis (`GET /cluster`, every 10 s): one Pi running every role, or three
  redundant Pis (processing / web = the hub address / AI) with who runs which role now,
  failovers in plain words and the AI HAT+ 2 state.
- **Sensors** (`/sensors`) — the real ESP32 hardware (air + water nodes), showing both
  what the devices report and what the hub makes of it:
  - **Analysis**: building status banner (status, headline, nodes online, active
    incidents) and per-zone cards with each node's indicators, headline and advice.
  - **One card per physical device**: online / stale / offline, firmware, last seen,
    uptime, Wi-Fi RSSI, zone selector (`hoa_manager` / `system_admin`). **Raw** panel =
    every field of the latest firmware status document, grouped like the firmware, with
    units and the device's own thresholds (the MQ5 gas value is a raw ADC count, not
    ppm) plus the verbatim JSON; **Analysis** panel = the hub's interpretation of that node.
  - **Raw history charts** per node (15 min / 1 h / 6 h / 24 h): air → CO, gas ADC,
    PM1.0/2.5/10, temperature + humidity, presence; water → sensor ADC with the
    device's wet/dry thresholds, leak latch.

The hardware API it consumes (`/buildings/{id}/summary`, `/buildings/{id}/nodes`,
`/nodes/{id}/history`, `PATCH /nodes/{id}`, WS `node` events) is specified in
[`../docs/HARDWARE.md`](../docs/HARDWARE.md).

## Stack

- **React 18 + TypeScript + Vite**
- **TanStack Query** for server state (polling fallback) + **WebSocket** for live push
  (the socket invalidates query caches: `incident`/`checkin` events refresh the incident
  queries, and an `incident` also refreshes the sensor summary, whose status follows open
  incidents; `node` events refresh only the sensor summary/nodes (bursts coalesced) and,
  at most every 10 s, the reporting node's history; unknown event types are ignored)
- **Recharts** for telemetry trends
- **react-router-dom** for routing + role-gated routes
- Floor plan is hand-rolled **SVG** (zones auto-laid-out, sensor dots colored by edge
  state, hazard heatmap on affected zones, pulsing SOURCE marker with its confidence on
  the triangulated source zone, falling back to the incident's first-detection zone). A
  production build overlays this on a real floor-plan image.

```
src/
  config.ts              API/WS base (VITE_API_BASE, same-origin when empty)
  api/                   client, types, react-query hooks
  auth/                  AuthContext (token in localStorage), LoginPage, RequireAuth
  realtime/              useIncidentSocket (WS -> query invalidation)
  components/            FloorPlan, TrendChart, IncidentTimeline, IncidentActions,
                         NodeCard, RawStatus, NodeHistoryCharts, Analysis, EnvironmentCard, ...
  lib/                   labels (zones, hazard/sensor names), nodes (raw-doc + level helpers)
  views/                 ManagerView, DispatchView, SensorsView
  App.tsx                router + authed layout
```

## Run

```bash
# backend first, from RPISoftware/: scripts/pi_setup.sh once, then docker compose up -d
# (or the backend alone without Docker: RUNME.md §2.2)
cd web
npm install
npm run dev               # http://localhost:5173, talks to http://localhost:8000
# different backend host:
echo "VITE_API_BASE=http://192.168.1.20:8000" > .env
```

Sign in as **`mihai`** (manager) or **`dispecer`** (dispatcher); building **`bld_007`**.
Trigger a hazard from the Manager view's "Simulate gas leak" button, or (from `RPISoftware/`):

```bash
docker compose --profile sim run --rm simulator --scenario gas_leak   # legacy demo sensors
docker compose --profile sim run --rm hw-sim --scenario co --fast     # firmware-accurate ESP32 nodes (/sensors)
```

Full walk-through, including the hub in Docker: [`../RUNME.md`](../RUNME.md) §2.

The Manager and Dispatch views update live: incident appears → floor plan marks the source zone →
dispatch shows occupancy vs accounted → resident check-ins (mobile app) drop the
unaccounted count.

## Same-origin deployment (Raspberry Pi hub)

On the Pi, nginx serves the built dashboard and proxies `/api` — including the
WebSocket upgrade on `/api/v1/ws/...` — to the backend. Build with an **empty**
`VITE_API_BASE` so the app talks to whatever host served it:

```bash
VITE_API_BASE= npm run build      # or ARG/ENV VITE_API_BASE="" in a Docker build
```

REST calls then use relative `/api/...` URLs and the WebSocket URL is derived from
`window.location` (`wss://` on https pages, `ws://` otherwise). Leaving the variable
**unset** keeps the `http://localhost:8000` default for `npm run dev`. `VITE_API_BASE`
is read at build time, so changing it needs a rebuild. The Docker image ignores a local
`.env` (`.dockerignore`) and always builds for same origin.

The WebSocket URL carries the user's JWT as `?token=`, so `nginx.conf` logs that
location without its query string and keeps its error log at `crit`.

## Build / typecheck

```bash
npm run build            # tsc --noEmit && vite build
npm run typecheck
```

## Notes
- Auth is the backend's dev token (username only, stored in `localStorage`), so run
  the dashboard on a trusted LAN/VLAN only ([`../RUNME.md`](../RUNME.md) §1.10). RBAC:
  `/manager` needs `hoa_manager`; `/dispatch` and `/sensors` need `dispatcher_external`
  or `hoa_manager`; `system_admin` sees all. Moving a node to another zone
  (`PATCH /nodes/{id}`) is offered to `hoa_manager` / `system_admin` only; dispatchers
  see the zone read-only. Backend enforces the same on each endpoint.
- Canonical gas readings can mix units (hardware MQ5 in raw `adc` counts, simulated
  sensors in `ppm`); the manager trend charts never put two units on one axis.
- Hazard "source" is the backend's triangulated zone (`est_source_zone_id`, rule-based,
  gas/CO from `verification` onward) with its confidence, shown on the floor plan and in
  the Dispatch view's "Hazard source (AI triangulation)" card; before an estimate exists
  it is the incident's first-detection zone. The learned model is a later phase
  (ARCHITECTURE.md §B).

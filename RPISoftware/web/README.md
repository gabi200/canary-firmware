# Canary — Operations Dashboard (React)

Role-based web console for the Canary safety platform. Implements ARCHITECTURE.md
**section C** — two views, live over WebSocket:

- **Manager / HOA** (`/manager`) — building floor plan with live sensor status,
  device health, environmental trends (gas/CO), active incidents with actions, and a
  demo "simulate gas leak" trigger.
- **Dispatch / emergency services** (`/dispatch`) — incident-centric: hazard source on
  the floor plan, live occupancy + **unaccounted-occupant count**, last-known occupied
  zones, evacuation progress, and the incident timeline + actions.

## Stack

- **React 18 + TypeScript + Vite**
- **TanStack Query** for server state (polling fallback) + **WebSocket** for live push
  (the socket invalidates query caches on each incident/check-in event)
- **Recharts** for telemetry trends
- **react-router-dom** for routing + role-gated routes
- Floor plan is hand-rolled **SVG** (zones auto-laid-out, sensor dots colored by edge
  state, hazard heatmap on affected zones, pulsing source marker on the incident's
  primary zone). A production build overlays this on a real floor-plan image.

```
src/
  config.ts              API/WS base (VITE_API_BASE)
  api/                   client, types, react-query hooks
  auth/                  AuthContext (token in localStorage), LoginPage, RequireAuth
  realtime/              useIncidentSocket (WS -> query invalidation)
  components/            FloorPlan, TrendChart, IncidentTimeline, IncidentActions, ...
  views/                 ManagerView, DispatchView
  App.tsx                router + authed layout
```

## Run

```bash
# backend first (repo root): docker compose up -d
cd web
npm install
npm run dev               # http://localhost:5173
# different backend host:
echo "VITE_API_BASE=http://192.168.1.20:8000" > .env
```

Sign in as **`mihai`** (manager) or **`dispecer`** (dispatcher); building **`bld_007`**.
Trigger a hazard from the Manager view's "Simulate gas leak" button, or:

```bash
docker compose run --rm simulator --scenario gas_leak
```

Both views update live: incident appears → floor plan marks the source zone →
dispatch shows occupancy vs accounted → resident check-ins (mobile app) drop the
unaccounted count.

## Build / typecheck

```bash
npm run build            # tsc -b && vite build
npm run typecheck
```

## Notes
- Auth is the backend's dev token (username only). RBAC: `/manager` needs
  `hoa_manager`, `/dispatch` needs `dispatcher_external` or `hoa_manager`;
  `system_admin` sees both. Backend enforces the same on each endpoint.
- Hazard "source" is the incident's primary zone (MVP). True AI triangulation is a
  later phase (ARCHITECTURE.md §B) — the marker/heatmap is already wired for it.

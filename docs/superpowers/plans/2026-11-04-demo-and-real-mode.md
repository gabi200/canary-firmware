# Demo and Real Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One hub-wide switch between a simulated Demo building and a Real building that shows only the connected ESP32s, followed by every web and phone screen.

**Architecture:** The mode is one Postgres row, served by `GET/PUT /api/v1/mode` together with the building it selects and whether the Real building has an alarm open. The web app and the phone app take their building id from that endpoint instead of the login form or config, so every existing per-building query switches with it. `bld_007` becomes the "Demo" building, fed by a long-running `building_sim` whose nodes carry a `demo-` base prefix; a new `bld_live` building with one room receives every other node. Demo incidents are mirrored onto the real nodes as buzzer TEST and valve CLOSE commands.

**Tech Stack:** FastAPI + SQLAlchemy async (backend, pytest), React + TanStack Query (web, `tsc`), Flutter/Riverpod (mobile), Python simulator, docker compose.

**Spec:** `docs/superpowers/specs/2026-11-04-demo-and-real-mode-design.md`

## Global Constraints

- Mode values: exactly `"demo"` and `"real"`. Default when no row exists: `"real"`.
- Demo building: `bld_007`, renamed `"Demo"`. Real building: `bld_live`, name `"Canary Live"`, floor `flr_live` (level 0, `"Parter"`), unit `unit_live` (`"Live"`, kind `common`), zone `zone_live` (`"Presentation"`, kind `hallway`, pos 0,0).
- Demo node prefix: `demo-` (setting `CANARY_DEMO_BASE_PREFIX`).
- Switching the mode: `system_admin` and `hoa_manager` only. Reading it: any signed-in user.
- Real-building incidents are never suppressed, hidden or delayed by the mode.
- The demo never opens an incident by itself: the demo simulator runs only `normal`.
- UI copy in both `en` and `ro` (web `web/src/i18n.tsx`, mobile `mobile/lib/src/i18n.dart`).
- Screens pick up a mode change within 5 s without a reload.

## Review Focus

1. **Real alarm while in Demo**: a gas reading on a `bld_live` node opens a normal incident and notifies `bld_live` residents, and `GET /api/v1/mode` reports `live_alarm: true` (Task 2 test `test_live_alarm_reported_in_demo`, Task 4 test `test_real_incident_unaffected_by_demo_mode`).
2. **Sim node registering before building_sim moves it** must land in Demo, never flash up in Real or its "new sensors" inbox (Task 3 test `test_demo_prefixed_node_lands_in_demo_building`).
3. **Migration run twice / on all three Pis at once** (each boots inside `schema_lock`): second run changes nothing and never moves a `demo-` node back to Live (Task 1 test `test_ensure_live_building_idempotent`).
4. **Mode flip with a stale browser tab or phone**: the screen still on the old building must switch on its next poll and its WebSocket must resubscribe (Task 6 manual check step, Task 7 manual check step).
5. **Mirroring on every state change** would hammer the real buzzer; mirror only on the first entry into an alarmed state and respect `commands.too_soon` (Task 4 test `test_demo_mirror_once_per_incident`).

---

### Task 1: Demo and Live buildings (settings, seed, one-time migration)

**Files:**
- Modify: `RPISoftware/backend/app/config.py`, `RPISoftware/backend/app/seed.py`, `RPISoftware/backend/tests/conftest.py`
- Modify: `RPISoftware/backend/app/main.py:121-127` (call the new function inside `schema_lock`, after `seed_if_empty`, whenever `auto_seed` is on)
- Test: `RPISoftware/backend/tests/test_live_building.py`

**Interfaces:**
- Produces: settings `demo_building_id: str = "bld_007"`, `live_building_id: str = "bld_live"`, `live_zone_id: str = "zone_live"`, `demo_base_prefix: str = "demo-"`, and new defaults `default_building_id = "bld_live"`, `default_zone_id = "zone_live"`; `async def ensure_live_building(session: AsyncSession) -> None` in `app/seed.py`; `seed()` calls it at its end so fresh installs and tests get both buildings.

Behaviour of `ensure_live_building` (idempotent):
1. Rename `bld_007` to `"Demo"` if its name is still `"Bloc A1"`.
2. If `bld_live` is missing: create building/floor/unit/zone from Global Constraints, `StaffBuilding(usr_mihai, bld_live)`, a `ResidentUnit` in `unit_live` for each seeded resident (`usr_ana`, `usr_ioana`, `usr_radu`, `usr_elena`), and **only in this same first run** move the nodes listed in setting `live_node_ids: list[str] = ["canary", "water-sensor"]` that exist in `demo_building_id` to `zone_live` with `NodeService.move` (the same call `PATCH /nodes/{id}` uses, so Device rows follow).
3. Never delete nodes (stale nodes are removed by hand in Task 8).

- [ ] **Step 1: Write the failing tests:**
  - `test_seed_creates_both_buildings`: after seed, `GET /api/v1/buildings/bld_live` as `mihai` → name `"Canary Live"`; `bld_007` name `"Demo"`; zones of `bld_live` == `["zone_live"]`.
  - `test_existing_real_nodes_move_to_live`: delete `bld_live` rows, add `Node(id="canary", mqtt_base="canary", building_id="bld_007", zone_id="zone_hallway", …)` and `Node(id="air-sensor", mqtt_base="air_sensor", …)`, run `ensure_live_building` → `canary` in `zone_live`, its `Device` rows in `bld_live`; `air-sensor` not moved.
  - `test_ensure_live_building_idempotent`: run twice; second run moves nothing (a node moved back into `bld_007` by hand stays there), no duplicate StaffBuilding/ResidentUnit rows.
  - `test_resident_sees_live_building`: as `ana`, `GET /api/v1/buildings/bld_live/summary` → 200.
- [ ] **Step 2: Run** `pytest tests/test_live_building.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** the settings, `ensure_live_building` and the `main.py` call. In `tests/conftest.py` add `os.environ.setdefault("CANARY_DEFAULT_BUILDING_ID", "bld_007")` and `os.environ.setdefault("CANARY_DEFAULT_ZONE_ID", "zone_hallway")` so existing hardware tests keep their landing zone; new tests override with `monkeypatch.setattr(settings, ...)`.
- [ ] **Step 4: Run** `pytest -q`. Expected: all pass (fix any test that asserted the name `"Bloc A1"`).
- [ ] **Step 5: Commit** `feat(backend): Demo building and Canary Live building`.

### Task 2: Hub mode setting and API

**Files:**
- Modify: `RPISoftware/backend/app/models.py` (new `HubSetting`)
- Create: `RPISoftware/backend/app/mode.py`
- Create: `RPISoftware/backend/app/api/mode.py`; register in `app/main.py` next to the other `include_router` calls
- Modify: `RPISoftware/backend/app/schemas.py` (`ModeOut`, `ModeIn`)
- Test: `RPISoftware/backend/tests/test_mode.py`

**Interfaces:**
- Consumes: settings from Task 1.
- Produces:
  - `class HubSetting(Base)`: table `hub_settings`, `key: str` PK, `value: str`, `updated_ts`, `updated_by: str | None`.
  - `app/mode.py`: `Mode = Literal["demo", "real"]`; `async def get_mode(session) -> Mode`; `async def set_mode(session, mode: Mode, user_id: str) -> None` (upsert key `"mode"`, adds an audit row the way `scope.audit` does); `def building_for(mode: Mode) -> str`; `async def live_alarm(session) -> bool` (an incident in `live_building_id` whose state is in `alarm|escalation|evacuation`).
  - `GET /api/v1/mode` → `ModeOut{mode, building_id, live_alarm}`; `PUT /api/v1/mode` body `ModeIn{mode}` → `ModeOut`, 403 for other roles, 422 for other values.

- [ ] **Step 1: Write the failing tests** in `tests/test_mode.py` (use `client` + `auth_token` from conftest):
  - `test_mode_defaults_to_real`: GET as `ana` → `{"mode": "real", "building_id": "bld_live", "live_alarm": False}`.
  - `test_manager_switches_mode`: PUT `{"mode": "demo"}` as `mihai` → 200, `building_id == "bld_007"`; GET as `ana` → `"demo"`.
  - `test_resident_cannot_switch`: PUT as `ana` → 403; as `dispecer` → 403.
  - `test_bad_mode_rejected`: PUT `{"mode": "party"}` → 422.
  - `test_live_alarm_reported_in_demo`: set demo, insert an `Incident(building_id="bld_live", state="alarm", …)`, GET → `live_alarm is True`.
- [ ] **Step 2: Run** `cd RPISoftware/backend && pytest tests/test_mode.py -v`. Expected: FAIL (404 on /api/v1/mode).
- [ ] **Step 3: Implement** the model, `app/mode.py`, schemas and router above. Upsert with `session.merge(HubSetting(...))` (works on SQLite and Postgres).
- [ ] **Step 4: Run** `pytest -q`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(backend): hub-wide demo/real mode setting and API`.

### Task 3: Route new nodes by base prefix

**Files:**
- Modify: `RPISoftware/backend/app/ingestion/hardware.py:391-460` (`_register`, `_landing_zone`)
- Test: `RPISoftware/backend/tests/test_hardware_ingest.py`

**Interfaces:**
- Produces: `async def _landing_zone(session, base: str) -> Zone | None` — base starting with `settings.demo_base_prefix`: `zone_hallway` if it is in `demo_building_id`, else that building's first zone; otherwise the existing default-building logic. Demo nodes get **no** `NodeInbox` row (they are placed by building_sim, not a technician).

- [ ] **Step 1: Write the failing tests** (monkeypatch `settings.default_building_id="bld_live"`, `default_zone_id="zone_live"`):
  - `test_demo_prefixed_node_lands_in_demo_building`: ingest an air status doc on base `demo-air-kitchen` → node in `bld_007`, no `NodeInbox` row.
  - `test_plain_node_lands_in_live_building`: base `canary` → node in `zone_live`, `NodeInbox` row present.
- [ ] **Step 2: Run** `pytest tests/test_hardware_ingest.py -v -k "lands_in"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `pytest -q`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(backend): demo- nodes register in the Demo building`.

### Task 4: Mirror demo incidents onto the real nodes

**Files:**
- Create: `RPISoftware/backend/app/demo_bridge.py`
- Modify: `RPISoftware/backend/app/incidents/service.py` (`_transition`, right after `self.notifier.on_state`, wrapped so a failure cannot break the safety path)
- Test: `RPISoftware/backend/tests/test_demo_bridge.py`

**Interfaces:**
- Consumes: `commands.send(session, node, command, user_id)`, `commands.too_soon(session, node_id)`.
- Produces: `async def mirror(session: AsyncSession, incident: Incident, from_state: IncidentState, to_state: IncidentState) -> list[DeviceCommand]` — only when `incident.building_id == settings.demo_building_id`, `to_state in ALARMED_STATES` and `from_state not in ALARMED_STATES` (a critical reading chains through several states in `forward_chain`, so this is what fires exactly once): for each online `Node` in `live_building_id`, air → `TEST`, water → `CLOSE`, skipping nodes where `too_soon` is true; `user_id="system:demo"`. Errors are logged, never raised into the incident path. Notifications need nothing new: the demo incident already notifies `bld_007` residents, who are the same users.

- [ ] **Step 1: Write the failing tests** (patch `app.commands.broker.publish` to record calls, as `tests/test_commands.py` does):
  - `test_demo_gas_leak_beeps_real_nodes`: online air + water nodes in `bld_live`; POST the "Simulate gas leak" telemetry (`device_id dev_gas_kitchen`, 6000 ppm, building `bld_007`) → published `(<air>/buzzer/set, "TEST")` and `(<water>/valve/set, "CLOSE")`.
  - `test_demo_mirror_once_per_incident`: the same incident moving further between alarmed states publishes nothing more.
  - `test_real_incident_unaffected_by_demo_mode`: mode `demo`, a gas incident in `bld_live` → no mirror commands, incident opens as before, `bld_live` residents get notification rows.
  - `test_offline_real_node_skipped`: offline node → no publish, no error.
- [ ] **Step 2: Run** `pytest tests/test_demo_bridge.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `pytest -q`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(backend): demo incidents sound the real buzzers and close the valve`.

### Task 5: Always-on demo simulator

**Files:**
- Modify: `RPISoftware/simulator/building_sim.py` (args at ~line 835; node bases at line 598-599; console loop at ~line 773)
- Modify: `RPISoftware/docker-compose.yml` (new `demo-sim` service)
- Test: `RPISoftware/simulator/test_building_sim.py`

**Interfaces:**
- Produces: `--base-prefix PREFIX` (default `""`, env `BASE_PREFIX`) prepended to every generated and configured base; `--no-console` (no stdin reading, runs until SIGTERM).
- `demo-sim` service: `profiles: ["demo"]`, `restart: unless-stopped`, `init: true`, `environment: <<: *sim-env, HUB_URL: http://backend:8000, BASE_PREFIX: demo-`, `command: ["--config", "rooms.demo.json", "--no-console", "--scenario", "normal"]`, no `stdin_open`/`tty`. Rooms in `rooms.demo.json` must not carry a non-`normal` `scenario`.

- [ ] **Step 1: Write the failing tests:**
  - `test_base_prefix_applied`: room `kitchen` with nodes air+water and `--base-prefix demo-` → bases `demo-air-kitchen`, `demo-water-kitchen`; an explicit `air_base: "x"` becomes `demo-x`.
  - `test_demo_config_is_all_normal`: every room of `rooms.demo.json` loads with `scenario == "normal"`.
- [ ] **Step 2: Run** `cd RPISoftware/simulator && python -m pytest test_building_sim.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** the flags and the compose service.
- [ ] **Step 4: Run** the tests and `docker compose config --profiles demo -q` from `RPISoftware/`. Expected: PASS, no compose error.
- [ ] **Step 5: Commit** `feat(sim): always-on demo simulator with demo- node prefix`.

### Task 6: Web follows the mode

**Files:**
- Modify: `RPISoftware/web/src/api/types.ts` (`HubMode`), `web/src/api/hooks.ts` (`useHubMode`, `useSetHubMode`)
- Modify: `RPISoftware/web/src/auth/AuthContext.tsx` (`buildingId` from mode), `web/src/auth/LoginPage.tsx` (drop the building field)
- Modify: `RPISoftware/web/src/components/Topbar.tsx` (switch + DEMO badge)
- Create: `RPISoftware/web/src/components/RealAlarmBanner.tsx`; render in `web/src/App.tsx`
- Modify: `RPISoftware/web/src/views/ManagerView.tsx:54-68,171-179` (demo card only in demo; `building_id: buildingId` from `useAuth`)
- Modify: `RPISoftware/web/src/i18n.tsx` (en + ro)

**Interfaces:**
- Consumes: `GET/PUT /api/v1/mode` (Task 2).
- Produces: `interface HubMode { mode: "demo" | "real"; building_id: string; live_alarm: boolean }`; `useHubMode()` (query key `["mode"]`, `refetchInterval: 5000`, enabled when signed in); `useSetHubMode()` (PUT, then `queryClient.invalidateQueries()` for everything). `AuthValue.buildingId` = `mode.building_id` when loaded, else `config.defaultBuildingId`; `config.defaultBuildingId` becomes `"bld_live"`. `Session.buildingId` is removed.
- Copy: badge `DEMO`; switch labels `Demo` / `Real` (ro `Demo` / `Real`); banner en `Real alarm in Canary Live` + button `Switch to Real`, ro `Alarmă reală în Canary Live` / `Treci pe Real`.

- [ ] **Step 1: Implement** the types, hooks and AuthContext change.
- [ ] **Step 2: Implement** the Topbar switch (visible to `system_admin` / `hoa_manager`; others see only the badge), banner (shown when `mode === "demo" && live_alarm`), ManagerView gating, i18n.
- [ ] **Step 3: Run** `cd RPISoftware/web && npm run build`. Expected: exits 0.
- [ ] **Step 4: Manual check** against a local backend (`docker compose up` or the Pis): sign in as `mihai` in two browsers, flip to Demo in one → within 5 s both show the Demo floor plan and the DEMO badge; flip to Real → only `Presentation` room with real nodes, no "Simulate gas leak" card; the incident WebSocket reconnects for the new building (devtools Network → WS).
- [ ] **Step 5: Commit** `feat(web): screens follow the hub's demo/real mode`.

### Task 7: Phone app follows the mode

**Files:**
- Modify: `RPISoftware/mobile/lib/src/services/api_client.dart` (`hubMode()`)
- Create: `RPISoftware/mobile/lib/src/state/mode_controller.dart`
- Modify: `RPISoftware/mobile/lib/src/state/session_controller.dart` (apply `session.copyWith(buildingId: …)` when the mode's building differs)
- Modify: `RPISoftware/mobile/lib/src/ui/home_screen.dart` (DEMO chip, real-alarm banner), `mobile/lib/src/ui/onboarding_screen.dart` (drop building field), `mobile/lib/src/config.dart` default `bld_live`, `mobile/lib/src/i18n.dart`
- Test: `RPISoftware/mobile/test/mode_controller_test.dart`

**Interfaces:**
- Consumes: `GET /api/v1/mode`.
- Produces: `class HubMode { final String mode; final String buildingId; final bool liveAlarm; factory HubMode.fromJson(Map<String, dynamic>) }`; `final hubModeProvider` polling every 5 s while signed in. Same copy as Task 6.

- [ ] **Step 1: Write the failing test** `mode_controller_test.dart`: `HubMode.fromJson({"mode":"demo","building_id":"bld_007","live_alarm":true})` fields; a session on `bld_live` + mode building `bld_007` → controller emits a session with `buildingId == "bld_007"`.
- [ ] **Step 2: Run** `cd RPISoftware/mobile && flutter test test/mode_controller_test.dart` (Flutter is not installed on this laptop: if `flutter` is missing, say so in the report and rely on the review). Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test` and `flutter analyze`. Expected: pass / no issues.
- [ ] **Step 5: Commit** `feat(mobile): app follows the hub's demo/real mode`.

### Task 8: Deploy to the three Pis and document

**Files:**
- Modify: `RPISoftware/RUNME.md` (mode switch, `demo` profile), `RPISoftware/docs/DEMO.md` (top section "Demo and Real mode")

- [ ] **Step 1: Docs**: how to flip the mode, that `COMPOSE_PROFILES=cluster,demo` runs the demo simulator on one Pi only, the safety rule (real alarms always fire; banner in Demo), and that "Simulate gas leak" also beeps the real buzzers and closes the real valve, which stays closed until someone opens it from the dashboard.
- [ ] **Step 2: Commit** `docs: demo and real mode`.
- [ ] **Step 3: Deploy** by push (Pis cannot pull): for each of `canary`, `canary2`, `canary3`.local, `git push ssh://canary@<pi>/home/canary/canary-firmware HEAD:refs/heads/deploy-incoming`, fast-forward there, `docker compose up -d --build` in `~/canary-firmware/RPISoftware`. On `canary2.local` only, set `COMPOSE_PROFILES=cluster,demo` in `.env` before `up`.
- [ ] **Step 4: Remove stale nodes** (after the user confirms the list): as `admin`, `DELETE /api/v1/admin/nodes/{id}` for `ops-drill-water`, `ops-e2e-water`, `ops-drill-smoke-water`, `ops-drill-air`, `ops-drill-smoke-air`, `ops-e2e-air`, `air-sensor`, `water-sensor-890b15`. A deleted node that is really alive re-registers in `bld_live` on its next status document.
- [ ] **Step 5: Verify on the hub** (`http://canary-hub.local`): `GET /api/v1/mode` → `real`, `bld_live`; nodes `canary` and `water-sensor` in `zone_live`; flip to Demo → Demo building with live `demo-*` readings and no incident for 5 minutes; press "Simulate gas leak" → incident opens and the real `canary` node beeps; flip back to Real.

# Demo mode and Real mode

## Why

Canary is shown at presentations in two ways: a staged story with a simulated building, and the
actual ESP32 sensors working live. Today both live in one building ("Bloc A1", `bld_007`): 7 seeded
sensors, the live `canary` air node, the `water-sensor` node (offline since 2026-10-27), 6 leftover
test nodes (`ops-drill-*`, `ops-e2e-*`) and 2 stale nodes (`air-sensor`, `water-sensor-890b15`, last seen
2026-10-22) are all assigned to the same rooms, so the screens mix fake and real data. The two must
be cleanly separated, and the presenter must be able to switch between them on the spot.

## What it is

One hub-wide **mode** switch, `demo` or `real`. Every screen follows it: web dashboard (laptop,
projector) and the phone app.

### Demo mode
- Shows only the **Demo building**: its rooms, simulated sensors, simulated history, and the scripted
  actions ("Simulate gas leak" and the rest).
- Simulated sensors produce live, **normal** readings continuously. Nothing escalates on its own:
  a gas leak (or any other incident) happens only when the presenter presses the button.
- A simulated incident behaves like a real one end to end: the **real** buzzers beep, the **real**
  valve closes, phones get the notification.
- Real sensors do not appear on any screen.

### Real mode
- Shows only the **Real building**: real, connected ESP32 nodes and their readings.
- No seeded sensors, no "simulated seed data" history, no simulate buttons.
- Starts simple: one building with one room; every real sensor lands there and is shown.

### Safety rule (both modes)
Real alarms always go off, whatever the mode. In Demo mode a real alarm fires in full (buzzer,
valve, notifications, escalation) and the screens show a clear **REAL alarm** banner so it cannot be
mistaken for part of the show.

## Goals
- One switch, applied everywhere within a few seconds.
- Demo and Real data never appear together on a screen.
- Demo incidents only on button press.
- Real alarm path unchanged and never suppressed by the mode.

## Non-goals
- Per-viewer modes.
- A rich floor plan for the Real building (one room is enough to start).
- Changing alarm thresholds, fusion, trust or baseline logic.

## Anti-goals (a failure even if it "works")
- A real gas reading silenced or hidden-without-banner because the hub is in Demo.
- A simulated sensor or simulated history visible in Real mode.
- The demo starting a gas leak by itself in front of an audience.

## Decided by the user
- Mode is hub-wide; every screen changes.
- Demo lives in its own building, named as the demo.
- Real does not use Bloc A1; it starts with something simple that just shows the sensors.
- Real alarms fire in Demo mode.
- Simulated incidents drive the real buzzers, valve and phone notifications.
- Demo never auto-triggers the gas leak; the presenter presses it.

## Builder's calls (Claude's, check these)
1. **Buildings.** `bld_007` becomes the Demo building, renamed "Demo" (keeps the seed, the
   simulators, `baseline_seed` and the evacuation what-if working unchanged). A new building
   `bld_live` "Canary Live" with one floor, one unit and one room "Presentation" is the Real building.
2. **Migration.** `canary` and `water-sensor` move to `bld_live`. The `ops-drill-*` / `ops-e2e-*` test nodes
   and the stale `air-sensor` / `water-sensor-890b15` nodes are deleted once the user confirms. Newly
   auto-registered nodes land in `bld_live` (`default_building_id`). Simulator nodes (hw_sim,
   building_sim) are configured to register in the Demo building.
3. **Where the mode lives.** One row in Postgres (replicated across the three Pis), read and set via
   `GET/PUT /api/v1/mode`. Switching is allowed for `system_admin` and `hoa_manager`. Default after
   a fresh install: `real`.
4. **How screens follow.** The web and phone apps read the mode and pick the building from it,
   replacing the hard-coded `defaultBuildingId` (`web/src/config.ts`, `mobile/lib/src/config.dart`).
   They re-check every few seconds (or ride the existing live channel if there is one), so a flip
   reaches every screen without a reload. The switch itself sits in the dashboard header, always
   visible to managers/admins, with a clear DEMO badge while in Demo.
5. **Simulated sensors in Demo.** A demo simulator runs on the hub in `normal` while the mode is
   `demo` (started/stopped by the backend or by a compose service gated on the mode), and is idle in
   `real`. The legacy `simulator` service's default `gas_leak` scenario is not used for this.
6. **Button press.** "Simulate gas leak" (and other scripted actions) target the Demo building and
   only render in Demo mode. The resulting incident triggers the same commands to the real nodes in
   `bld_live` (buzzer TEST/alarm, valve CLOSE) and the normal notification path to phones.
7. **Real alarm during Demo.** Incidents from `bld_live` are always processed. While in Demo, the
   web and phone apps poll for open real incidents and show a REAL alarm banner with a one-tap
   "switch to Real".
8. **Users.** The existing users see whichever building the mode selects (staff/resident scoping is
   extended to both buildings), so the same logins work in both modes.

## Left to the builder
- Exact UI of the switch and badge; i18n strings (EN + RO).
- Whether the demo simulator is an in-backend task or a compose service.
- Tests: mode switch API, building selection by mode, real incident handled in Demo, no
  auto-incident in Demo.

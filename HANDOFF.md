# Handoff: Evacuate screen redesign

Branch: `feat/evacuate-route-line` · Last updated: 2026-09-30

## Done

- **Backend.** `GET /buildings/{id}/evacuation` returns `waypoints` (`id`, `label`, `kind`, `hint`)
  with human-readable names, skips malformed path entries instead of failing, and orders
  routes deterministically. The seed route uses real Romanian names and hints.
  101 tests pass.
- **Mobile, Evacuate screen (model A, "route line").** `lib/src/ui/alarm_screen.dart`,
  `widgets/route_line.dart`:
  - hazard header with a Live/Offline chip; Minimize replaces the ✕
  - a "don't" line per hazard type (`logic/hazard_advice.dart`)
  - vertical route: Start here → steps with hints → assembly point, plus an "Avoid: <zone>" marker
  - a pinned action bar: I'm out and safe / I need help / Call 112 (`url_launcher`) /
    Safe but still inside; the check-in can be changed later
  - haptic pulse on open; the screen stays awake (`wakelock_plus`)
- **Mobile, route safety.** `logic/route_selection.dart` rates each route `clear`, `unknown` or
  `crosses` against every affected zone. The screen shows a red warning for `crosses` and an
  amber one for `unknown`. Parsing skips malformed routes and waypoints instead of dropping
  everything. 21 tests pass; `flutter analyze` reports no errors or warnings.
- Verified by hand on the Pixel 9 Pro XL emulator with a simulated gas leak.

## To do next

1. Widget tests and golden screenshots for the Evacuate screen: each hazard type,
   `crosses` / `unknown` warnings, offline chip, check-in → Change flow, 2× text scale.
2. Home screen shows raw IDs: `bld_007` in the app bar and `zone_kitchen` in the red
   EVACUATE banner (`home_screen.dart`, `flashing_evacuate_banner.dart`). Use the building
   name and `zoneLabelsProvider`. Sweep `lib/src/ui` for other raw IDs and literal colors.
3. Romanian localization (`flutter_localizations` + ARB files) with diacritics. The UI is
   English while the building data is Romanian.
4. Freshness chip: the incident controller sets `connected` when a WebSocket attempt
   *starts*, so "Live" can show before the socket is up. Set it on the first message or
   ack, and show "Updated N s ago".
5. Cache the last evacuation info locally so the route still shows offline
   ("Offline · showing saved route").
6. Optional read-aloud of the next step (TTS).
7. Floor-plan view (model C) as a "See on floor plan" toggle above the route line.

## Known safety limits (from a safety review, deferred)

These need a real route graph on the backend. They matter for real buildings, not the demo.

1. **Resident location is unknown.** The session has no unit or zone, so `userZoneId` is always
   null and the route starts at "Start here" instead of "Ap. 12". Add the resident's unit and
   floor to the token or session and filter routes by floor before ranking.
2. **Routes don't list every zone they pass through.** A kitchen or bedroom hazard isn't on the
   hallway route, so the route is rated `clear`. Store full traversed-zone membership per route.
3. **Exits and assembly points aren't linked to hazard zones,** so a hazard at an exit can't
   block a route. Support alternate assembly points.
4. **When every route crosses the hazard,** the app still shows one, with a red warning. Consider
   a separate "no safe route" state with shelter-in-place or dispatcher instructions.
5. **Unknown waypoint IDs** get a humanized label instead of invalidating the route. Validate
   route data when it is written.
6. **Seed changes only reach fresh databases** (`seed.py` returns early if `bld_007` exists).
   Use migrations or reviewed upserts for route data.

## Working notes

- **Running locally:**
  - Stack: `cd RPISoftware && docker compose up -d --build`. Dashboard at http://localhost,
    API at :8000.
  - Demo sign-in is username only: `mihai` (manager), `ana` (resident).
  - Web app: `flutter run -d chrome --dart-define=CANARY_API=http://localhost:8000`
  - Android: `flutter run -d emulator-5554`. Use the `Pixel_9_Pro_XL` AVD; `Medium_Phone_API_35`
    didn't start.
  - Dashboard → Simulate gas leak starts a critical gas incident that goes straight to evacuation.
- **Reset demo data:** `docker compose stop backend && docker compose rm -f backend && docker volume rm canary_backend_data && docker compose up -d backend`.
  This deletes all local incidents and check-ins.
- UX proposal with the three layouts: https://claude.ai/artifact/QgHFnS4zFJWC9FQUtKbGr7

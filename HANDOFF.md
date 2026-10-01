# Handoff: Resident app UX

Branch: `feat/read-aloud` (stacked: `feat/home-labels-freshness` → `feat/evacuate-tests-offline` →
`feat/romanian-l10n` → `feat/read-aloud`; none merged into `main` yet) · Last updated: 2026-10-01

## Done

- **Evacuate screen redesign** (model A, route line), merged into `main` on 2026-09-30.
- **#2 Names, not IDs.** `GET /buildings/{id}/summary` returns `building_name`; app bars show it, and
  zones and incident states go through `logic/display_labels.dart`. Literal colors moved to theme tokens.
- **#4 Honest Live chip.** The incident WebSocket sends `hello` on connect and `ping` every 15 s. The app
  is Live only after a frame, goes offline on a drop or after 40 s of silence, and shows "updated N s ago".
  Queued check-ins retry on every frame without overlapping or losing check-ins queued mid-flush.
- **#5 Offline route.** The last good evacuation route is cached per building (warmed from Home) and
  shown with a "Saved route from HH:mm" notice when the hub is unreachable.
- **#1 Tests.** Widget tests and goldens for the Evacuate screen (hazard types, crosses/unknown, chip,
  check-in → Change, 2× text, no route, Romanian at 2×). Goldens use the Ahem test font; regenerate with
  `flutter test --update-goldens` and look at `test/goldens/*.png`.
- **#3 Romanian.** gen-l10n ARB catalogs in `lib/l10n` (Romanian default, English if the device is
  English). Comma-below diacritics are enforced by a test. Hub data is not translated.
  After editing an ARB file run `flutter gen-l10n`; generated code in `lib/l10n/gen` is committed.
- **#6 Read aloud.** "Citiți cu voce tare" next to the route heading (`flutter_tts`, behind
  `speechProvider`). Never automatic; stops on check-in, minimize and dispose.
- **#7 Floor plan (schematic, demo only).** "Vedeți pe schiță" toggle above the route line. Built from zone
  `pos_x`/`pos_y` only, with a permanent "Schemă orientativă · nu la scară" badge. Not a real map.
- Checks on `feat/read-aloud`: `flutter analyze` (5 pre-existing infos), `flutter test` 64 passed,
  backend `pytest` 102 passed (backend last changed in #2/#4). Not yet checked on the emulator.

## To do next

1. **Next session:** check on the Pixel 9 Pro XL emulator. Rebuild the stack first (`docker compose up -d --build`; the backend changed in #2/#4). Simulate a gas leak, then check: building name and zone labels on Home, "Conectat · actualizat acum N s", airplane mode → saved route notice and offline chip, read aloud in Romanian, the floor-plan toggle, check-in → Modifică
2. Merge the stacked branches into `main` (or open one PR from `feat/read-aloud`) after the emulator check
3. Native-speaker review of Romanian copy: "Evidența persoanelor", "Alertă: {hazard}", "Conectează locuința", "Vedeți pe schiță"
4. Onboarding and settings still show the raw building ID field (by design for setup); hide it behind an "Advanced" toggle
5. Real floor geometry on the backend (rooms, stairs and exit positions) so the floor plan can become a map; ties into safety limits 1–3 below

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

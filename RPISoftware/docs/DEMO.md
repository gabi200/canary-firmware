# Canary AI feature demo

## Demo and Real mode

The hub is in one mode at a time. Flip it with the **Demo / Real** switch in the dashboard's top
bar (`mihai` or `admin` only; everyone else sees the mode but cannot change it). Dashboard and
phones follow within 5 s. A fresh hub starts in **Real**.

| | Real | Demo |
|---|---|---|
| Building | `bld_live` "Canary Live" (room "Presentation") | `bld_007` "Demo" |
| Sensors | the real ESP32 nodes | `demo-*` nodes from the `demo-sim` service |
| "Simulate gas leak" | hidden | shown |
| What-If tab | hidden | shown |

Before presenting:
- On **one** Pi, `.env` has `COMPOSE_PROFILES=cluster,demo` (starts `demo-sim`). Check that Demo
  shows live readings and no incident.
- Phones need a rebuilt app to follow the mode. It has not been compiled yet: run
  `cd mobile && flutter pub get && flutter test && flutter analyze` first.
- Every section below that uses `mihai` and the kitchen, `bld_007` or "Simulate gas leak" needs
  **Demo** mode. Real mode shows only the real sensors.

**Simulate gas leak (Demo only).** It opens a simulated incident. Once it starts alarming, the hub
also sends a buzzer TEST to the online real air sensors and a valve CLOSE to the online real water
sensors in Canary Live, and phones get the notification. This happens only while the hub is in Demo.
- The real valve **stays closed** until someone sends OPEN from the dashboard. Do this after the demo.
- Commands to one node are limited to one per 3 s: a mirrored command can skip a node commanded in
  the previous 3 s, and an OPEN or SILENCE right after the mirror can be refused. Retry.

**Real alarms always go off.** If a real sensor alarms while the hub is in Demo, the screens show a
"Real alarm in Canary Live" banner (phones too, with a notification). The dashboard banner offers
**Switch to Real** to `mihai` / `admin`.

Real sensors that stop reporting stay visible, marked *lost*.

## F3a: fusion explanation

1. Start the existing Canary stack, sign in to the web dashboard as `mihai`, and open **Dispatch**.
2. Publish the labelled **brief PM spike with flat CO** replay through the normal telemetry path.
   - Open the active incident and find **Fusion explanation** below the hazard-source card.
   - Expected screen: a benign score shown as a heuristic from 0 to 1, the current classification, a brief-spike supporting reason, flat or below-threshold CO under contradicting evidence, and an age/status row for every input.
3. Reset the replay data, then publish the labelled **PM plus rising CO** replay.
   - Expected screen: PM channels from one instrument count as one fresh witness, CO appears as a separate fresh witness, and the supporting evidence reflects the corroboration. The panel must not present the score as a probability.
4. Reset the replay data, then publish the labelled **CO missing** replay.
   - Expected screen: carbon monoxide appears under **Missing inputs** and its input row is marked **missing** with no age. The missing input must not appear healthy.
5. During any replay, trigger a critical reading or local device alarm.
   - Expected screen: **Active overrides** states that the critical or local alarm remains authoritative. The incident alarm path continues unchanged regardless of the advisory score.

The panel polls the existing `/api/v1/incidents/{id}/fusion` endpoint. It recomputes from recent inputs, so its score can differ from the score stored when the incident last changed state.

## F1: sensor trust and drift

1. Open **Sensors** and keep the matching **Device health** card visible on the Manager screen.
2. Publish the labelled **frozen channel** replay long enough to exceed the channel's stuck limit.
   - Expected screen: the node trust state becomes **suspect** with the reason **channel unchanged too long**. Readings remain visible and continue through the normal hazard path.
3. Publish the labelled **baseline shift** replay with a clean earlier reference window and shifted recent samples.
   - Expected screen: the node becomes **suspect** with **baseline shift, cause unknown**. Do not present drift as proof of sensor failure.
4. Unplug a reporting sensor or stop its normal status and telemetry messages for more than three reporting intervals.
   - Expected screen: the node becomes **lost** with **coverage lost** in both Device health and the node card. It must not fall back to green.
5. Restore normal reporting and allow enough clean history for a new assessment.
   - Expected screen: the node returns to **OK** only when the endpoint reports `ok`; while the assessment is loading or unavailable, the UI shows an unknown/unavailable state.

A flat binary water probe is expected to remain **OK**. Temperature or humidity changes may move readings without proving a device fault.

## F2: ESPectre motion evidence

Setup: the two ESPectre boards are flashed (docs/ESPECTRE.md), connected to the hub broker, and
mapped in `CANARY_ESPECTRE_ZONES` (for example the C3 in the kitchen, the S3 in the bedroom).
Log in to the dashboard as `mihai` (manager).

1. **Board starting up.** Power a board on. In the Motion card under the floor plan, its room
   shows *Calibrating* (amber), and its floor-plan tile has a *Calibrare* / *Calibrating* chip.
2. **Empty room, board ready.** Wait for calibration to end. The room shows *No recent motion*
   (grey) with "last motion …" or "no motion seen yet". The card's caption says this is not proof
   the room is empty.
3. **Walk in.** Walk into the room. Within about 5 s the tile gets a blue *Motion* chip and the
   card shows *Motion detected*, "last motion just now".
4. **Leave.** Walk out. About 30 s after the last motion the room goes back to *No recent motion*,
   and the age keeps counting up.
5. **Unplug a board.** Pull its power. The broker publishes its Last Will, or the board falls silent
   for 60 s. The room shows *Unavailable* (dashed grey chip), never green.
6. **Rooms with no board** show *No presence sensor* in the card and no chip on the plan.
7. **Alarm unaffected.** In Demo, press "Simulate gas leak" with a board showing *No recent motion* in the
   kitchen: the incident still goes straight to evacuation.

Not shown to dispatchers or residents (the endpoint answers 403; the card and chips are hidden).

## F4: Learned normal per room

Each room's gas, CO and particulate readings are compared with that room's own frozen reference:
median and MAD over the 14 days that ended yesterday, without incident windows or readings the
node flagged. Hour-of-day buckets are used once there are 7 days of history. Readings are kept
for `CANARY_RETENTION_DAYS` (14), so a reference covers about 13 days. The comparison is evidence
only: the score is a heuristic in MAD units, not a probability, and alarm thresholds are unchanged.

Setup (a hub without two weeks of history): seed labelled demo references, then restart the
backend or wait for the next page refresh.

```
cd backend && python -m tools.baseline_seed --building bld_007
```

1. **Seeded rooms.** Log in as `mihai`. The card "Usual for this room?" lists each room and metric
   with a *simulated seed data* tag. With live sensors reporting normally, each shows *Usual* and
   "x vs usual y (z spreads)".
2. **Hour buckets.** In a kitchen between 18:00 and 21:00, the particulate line says "at 19:00":
   the seed's dinner-time bump is that hour's normal, so cooking smoke reads as less unusual than
   at 03:00.
3. **Unusual reading.** Breathe on the CO sensor or light a match near the air node, below the
   alarm threshold. Within 15 s the room shows *Higher than usual* (amber) with a score above 3.
   No incident opens until the absolute threshold is crossed.
4. **No data.** Unplug the air node. After 10 minutes its rooms show *No recent data*, never
   *Usual*.
5. **Learning.** On a fresh hub without the seed, rooms show *Still learning* with the sample
   count. The hourly job on the processing node replaces seed or learning rows once a room has
   200 samples over at least 24 h.

## F5: Water-leak impact map

Setup: `CANARY_WATER_TOPOLOGY_FILE=docs/water_topology.example.json` (the path is relative to where
the backend runs; in Docker, mount it and use the in-container path). Restart the backend.

1. **Leak.** Wet the water node's probe (or post a `water_leak` reading of 1 with `edge_state: alarm`
   for `dev_leak_kitchen`). A water-leak incident opens for Ap. 12.
2. **Manager view.** Under the incident, "Potentially affected units" says "Leak in: Ap. 12" and
   then lists: `unit_0212` *directly below* (amber), `unit_0112` *2 floors below*, and `unit_0412`
   *shares riser riser_kitchen_A*. Units missing from the demo seed show their ids.
3. **Dispatch view** (`dispecer`): the same list, as a card next to the incident brief.
4. **Plan missing.** Clear `CANARY_WATER_TOPOLOGY_FILE` and restart. The card says the impact is
   *Unknown: the plumbing plan is not configured*, not "no units".
5. **Nothing automatic.** The incident's state, its timeline and the valve are unchanged by the
   map. Closing the valve stays a manual command.

## F6: Evacuation what-if

A staff-only tool on a **simulated** floor graph (`backend/app/scenario/demo_graph.json`: three
apartments, a corridor, two stairs, a lobby and two exits, with made-up head counts). It is
separate from the building's `EvacuationRoute` data and from any incident, and every screen says
"scenario — not a safety prediction". There is no smoke spread and no walking speed.

1. Log in as `mihai` and open **Administration → What-if**. The dashed amber banner labels
   it a scenario.
2. **Nothing blocked.** Every apartment goes Floor 3 corridor → Stair A → Lobby → Main entrance (Ap.
   12: 35 m). The busiest passage is Stair A ↔ Lobby: 9 people at 30/min, 0.3 min to clear.
3. **Block Stair A.** The paths switch to Stair B → Back door, and the busiest passage becomes
   Stair B ↔ Back door (9 people at 20/min, 0.45 min).
4. **Block the Floor 3 corridor.** Every apartment shows *No exit reachable* in red, with "9
   simulated people with no exit".
5. **Isolation.** The resident app's Evacuate screen and `GET /buildings/bld_007/evacuation` are
   unchanged.

## F3b: Fusion evidence and observed sequence

Both are read-only. The room evidence is labels only: it never changes the benign score or the
classification, and motion is always weak context, so it can never make a hazard look benign.

1. Log in as `mihai`, open **Dispatch** and start an incident in the kitchen (for example a gas
   reading over the detection threshold on `dev_gas_kitchen`).
2. **Room evidence.** Under **Fusion explanation**, the **Room evidence** block groups items by
   role: *Supports a hazard*, *Points away from a hazard*, *Context*, *Missing or unreliable*.
   - Kitchen gas higher than its own frozen normal (F4) supports a hazard.
   - Kitchen gas close to its normal points away from a hazard and is marked **weak**.
   - An ESPectre board in the room (F2) shows as *Motion detected* or *No recent motion*, always
     weak context. No board shows as *No presence sensor* under missing.
   - Each kitchen sensor's trust (F1) shows as context; a *lost* sensor shows under missing.
3. **Alarm regression.** Seed a kitchen gas normal of 6000 ppm and send a critical 6000 ppm
   reading with a local alarm. The incident goes to evacuation, the room-normal item says *Usual*
   (weak, points away), and the score stays 0 with the classification *genuine*.
4. **Observed sequence.** Below the replay bar on the hazard map, **Observed sequence** ranks each
   sensor by when it first crossed its threshold, from stored readings. It flags data gaps (a
   silence over 3x the sensor's usual interval, at least 60 s) and readings received out of order.
   Duplicate deliveries are dropped at ingest and do not add an arrival. While replaying, sensors
   that had not crossed yet at the replay time are dimmed.
5. Stored source estimates and motion events are counted on their own line, not merged into the
   sequence. Opening the panel never recomputes triangulation (no new snapshot is written).

API: `GET /api/v1/incidents/{id}/fusion` (`evidence_items`) and
`GET /api/v1/incidents/{id}/evidence-timeline`, staff only.

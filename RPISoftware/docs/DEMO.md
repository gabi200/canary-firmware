# Canary AI feature demo

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
7. **Alarm unaffected.** Press "Simulate gas leak" with a board showing *No recent motion* in the
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

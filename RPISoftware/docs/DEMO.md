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

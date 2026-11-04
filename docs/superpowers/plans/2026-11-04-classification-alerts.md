# Classification alerts implementation plan

**Goal:** Display visible rule-based and evaluation-model classification alerts throughout the web dashboard and phone app. The user selected visible alerts only, without additional phone notifications.

**Approach:** Reuse each active incident's existing REST `signature` payload. Display the latest rule verdict, confidence score, evidence, timestamp, and the separately labelled evaluation-only random-forest estimate. Keep existing gas/CO/evacuation decisions and notifications unchanged. Classifications are estimates, not an all-clear.

**Selection:** Show active incidents when either layer has one of `smouldering_fire`, `flaming_fire`, `gas_leak`, `steam`, `cooking`, `aerosol`. Hide closed incidents and all-normal/unknown results. Model-only hazard suggestions are informational; they do not become actual alarms. Preserve the active alarm instructions alongside benign classifications.

## Work
- [ ] Dashboard: shared visible component above routed content, reusing useIncidents and existing styles. EN/RO labels, evidence expansion, timestamp, scroll bounds and accessible live status. Verify normal/unknown/closed hiding, model disagreement, active evacuation instructions and updated classification with browser fixtures. Build production bundle.
- [ ] Mobile: parse signature into Incident; visible global alert above Navigator including secondary screens. Add bounded background REST refresh while signed in so same-state classification changes appear, protect disposed/stale requests, preserve signature across partial WebSocket updates, and do not issue new notifications. Add localization, model/controller/widget tests. Run Flutter test/analyze.
- [ ] Review integrated change, deploy web to the Pis, build Android APK, and verify current live classifications and cluster health. Do not inject hazard telemetry or trigger buzzers/valves for visual testing.

## Review focus
- Experimental model results never replace an active alarm or alter its severity.
- Alerts do not mix buildings on a mode change or survive logout.
- Missing/old server signature data is tolerated; timestamp identifies the latest assessment.
- Secondary app routes still show the classification alert.
- A slow REST response cannot erase a more recent incident event.

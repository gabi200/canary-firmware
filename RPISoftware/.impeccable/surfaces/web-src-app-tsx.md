---
version: 1
slug: "web-src-app-tsx"
primary_target: "web/src/App.tsx"
related_targets: ["web/src/styles.css"]
---

# Operations dashboard (web)

Scope: every authenticated route of `web/` (Manager, Dispatch, Sensors, Administration), plus Login and the public Join page. Mode: Operate.

Audience and job: the dispatcher during an incident first (hazard source, occupancy, unaccounted residents), then the HOA manager and the technician.

Confirmed by the owner (2026-11-10):
- A professional, clean dashboard look. This is the category standard, chosen on purpose.
- It should sit alongside Linear / Vercel (restraint, thin borders, precise type) and UniFi / Home Assistant (device cards, floor maps).
- Light and dark themes; dark is the default.
- Reach: new visual system and a new app shell. Every feature, route, text and behaviour stays.
- Hazard language keeps its meaning (green / amber / red, evacuation stripes, ISO pictograms) and is redrawn to pass contrast in both themes.
- 2026-11-11: the evacuation banner becomes a contained panel like every other (8px radius, one pictogram size, state tag inline, advice signs in a band at its foot); the hazard tape may be streamlined or removed (owner: "you can change the hazard tape, remove it if needed, it should be streamlined"); motion is one calm signal, the exit pictogram's gentle pulse, with a still background.

## Direction contract

THESIS: A quiet console where colour means state and nothing else. It refuses the decorated-card dashboard: no coloured side stripes, no glows, no uppercase label noise, so an alarm is the loudest thing on any screen.

OWN-WORLD: Cool near-neutral surfaces in three steps (ground, panel, raised) separated by 1px hairlines; 8px radius; Inter throughout with tabular numerals; one blue accent for action and selection; green / amber / red only for state, each as a solid dot or fill plus a soft tint; violet reserved for priority residents. The Canary wordmark keeps its yellow dot.

STORY: The user always knows where they are (left rail), whether the building is safe (state colour and the incident count on Dispatch), and what to do next (one primary action per panel).

FIRST VIEWPORT: Left rail 232px: wordmark, four destinations with icons, then connection state, building, role and sign out at the foot. A 52px utility bar over the content: page name left; Demo badge, Demo / Real switch, language and theme switches right. Content starts directly under it; on Dispatch the incident banner is the first block and the Evacuate action stays in its first screen.

FORM: Category standard, pinned by the owner; position n/a. seed: none (direction pinned by the owner, no roll run; the owner exempted the roll on 2026-11-11: "record it as exempt"). Signature: the shell reports the building state on every page through the incident count on the Dispatch destination.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

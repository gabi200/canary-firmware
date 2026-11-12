---
version: 1
slug: "mobile-lib-src-ui-home-screen-dart"
primary_target: "mobile/lib/src/ui/home_screen.dart"
related_targets: ["mobile/lib/src/theme.dart"]
---

# Resident app (Flutter, mobile/)

Scope: every screen of `mobile/lib/src/ui` (sign-in, find hub, home, rooms, sensors, chart, alarm / evacuation, household, care profiles, settings, account, invite, sensor test, manager dashboard). Mode: Operate.

Audience: residents at home (everyday) and under alarm (stress); managers / dispatchers on the manager dashboard. Job: know the home is fine at a glance; under alarm, know where the hazard is, what not to do, the way out, and tap "I'm safe".

Constraints (user, 2026-11-12): join the console system in DESIGN.md; alarm screens stay loud, full-screen and readable under stress; Romanian labels must fit without truncation; keep light and dark following the phone; must not look like a generic smart-home app. Analysis only, never raw measurements; occupancy only for managers.

## Direction contract

THESIS: The phone is the console's quiet sibling: one status block that says how the home is, then the rooms as plain labelled cards. It refuses the smart-home template of glossy icon tiles, pill buttons and seed-colour Material chrome.

OWN-WORLD: Console tokens on both themes: ground / panel / raised, 1px hairlines, 8px containers, 6px controls, Inter with tabular numerals, sentence case, one Action Blue, green / amber / red only for state as dot + text + soft tint. Yellow wordmark dot. No shadows at rest, no pill buttons.

STORY: The resident opens the app, reads one sentence, sees which room (if any) needs a look, opens it for advice. Under alarm the whole phone turns to the incident banner language: fill by state, ISO pictograms in white circles, a darker advice band, the where-are-you check-in, then the danger sketch and route, with a fixed check-in bar.

FIRST VIEWPORT: 52px bar (yellow dot + unit title left; neutral Demo badge, settings right). Status block tinted by state with "Live" line, 24px headline, one supporting line. Emergency-profile prompt as a panel row with an outline button. "My rooms" heading with blue "All sensors" link; two-column room cards (name 600, state dot top right, one muted headline; attention rooms take the amber border and tint). Building strip. Bottom navigation Home / Household / Settings.

FORM: Status block over room cards; dealt structure 1 of 3 on the table (position 3 on the ranked list). seed:3f94e74588d7dfe7

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

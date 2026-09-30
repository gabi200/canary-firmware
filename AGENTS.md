# AGENTS.md

Instructions for coding agents (Codex, Claude Code) working in this repository.

## Project

Canary is a building-safety platform: **detection → alert → evacuation → victim-accounting**.

| Path | What | Stack |
| --- | --- | --- |
| `water_sensor/` | Leak sensor firmware | ESP32-C3, Arduino C++ |
| `air_sensor/` | Gas / CO / PM / radar firmware | ESP32-S3, Arduino C++ |
| `RPISoftware/backend/` | Hub API, detection, incidents, evacuation | Python 3.12, FastAPI, SQLAlchemy |
| `RPISoftware/web/` | Operations dashboard (raw + analysis) | React + TypeScript, Vite |
| `RPISoftware/mobile/` | Resident app (analysis only) | Flutter, Riverpod, dio |
| `RPISoftware/simulator/` | Hardware and legacy sensor simulators | Python |

Read before changing behavior:
- `RPISoftware/ARCHITECTURE.md`: the plan and its "As built" section
- `RPISoftware/docs/HARDWARE.md`: the firmware ↔ hub contract (MQTT, status documents, API)
- `RPISoftware/DEBUG.md`: checks and troubleshooting

## Checks

Run from the repository root:

```sh
./water_sensor/scripts/run-native-tests.sh
./air_sensor/scripts/run-native-tests.sh
bash RPISoftware/scripts/smoke.sh        # backend tests, web typecheck/build, infra checks
```

Mobile (from `RPISoftware/mobile/`):

```sh
flutter pub get
flutter analyze
flutter test
```

Run the checks for every project you touched before you say a task is done. Report
failures with their output; do not hide or skip them.

## Rules

- **Safety-critical path.** Alerts, evacuation routing, and check-in must fail safe. Never
  suppress or delay an alarm to make the UI cleaner. When unsure, show more, not less.
- **Mobile shows analysis only.** Keep raw measurements (ppm, ADC, µg/m³, °C, %RH, RSSI)
  off the resident app. They belong on the web dashboard.
- **Residents never see occupancy.** Only managers, dispatchers and admins see who is home.
- **Canonical vocabularies** live in `RPISoftware/backend/app/enums.py`. Don't invent new
  status strings in clients.
- Match the style of the surrounding code. Keep changes scoped to the task.
- Never commit secrets. `.env` and the Mosquitto password file stay local.
- Don't commit or push unless asked. Branch first if on `main`.

## Mobile UI conventions

- The hazard color language is in `lib/src/theme.dart` (normal / warning / alarm /
  evacuation). Use its tokens, not literal colors.
- An emergency screen must work one-handed, in the dark, under stress, and with gloves:
  touch targets of 48 dp or more, text of 16 sp or more, one primary action per screen,
  and meaning carried by icon + text as well as color.
- Evacuation UI lives in `lib/src/ui/alarm_screen.dart` and
  `lib/src/ui/widgets/evacuation_map.dart`. Data model: `lib/src/models/evacuation.dart`.

## Delegation tiers

The orchestrator (Claude Code) routes work to the cheapest tier that can do it well.
Codex roles are defined in `.codex/agents/`.

| Tier | Codex role (`agent_type`) | Model | Effort | Use for |
| --- | --- | --- | --- | --- |
| 1 | `scout` | `gpt-6-luna` | low | Read-only search, summaries, mechanical edits, renames, running checks |
| 2 | `builder` | `gpt-5.6-terra` | medium | Well-specified features and fixes in one area, tests, UI widgets from a spec |
| 3 | `engineer` | `gpt-6-sol` | medium | Multi-file or cross-stack work, UI redesigns, non-obvious bugs, reviews |
| 4 | `expert` | `gpt-5.6-sol` | high | Hardest only: safety-critical logic, concurrency, tricky root causes. Ceiling: never go above this |

Claude-side helpers: Haiku for quick lookups and file sweeps, Sonnet for focused
implementation or review.

Rules for delegated work:
- Every task needs a clear goal, the files involved, the acceptance check, and what is out of scope.
- Start at the lowest tier that fits. Escalate one tier only after a real failure, and say why.
- Parallel agents must not edit the same files.
- The orchestrator reviews every diff and runs the checks before accepting it.
- The Codex sandbox cannot write to the Flutter SDK or the backend venv, so `flutter` and
  `pytest` fail inside it. Codex agents write code and tests but don't try to run those
  checks or work around the sandbox; the orchestrator runs them.
- Designs in a delegated task are pre-approved. Implement them directly without a design-approval step.

From Claude Code, delegate to Codex with the `codex:rescue` skill, for example:
`--model gpt-5.6-terra --effort medium <task>`.

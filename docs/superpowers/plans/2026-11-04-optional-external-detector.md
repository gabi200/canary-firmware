# Optional external detector implementation plan

> Use superpowers:subagent-driven-development to execute the independent firmware and backend tasks, then review the integrated change.

**Goal:** Configure the external gas detector per sensor from the dashboard, persist the choice, and update only canary-black over OTA.

**Architecture:** Reuse node commands: DETECTOR_ON and DETECTOR_OFF on `<base>/gas-detector/set`. Firmware persists `gasDetectorEnabled`; status reports `gas_detector.enabled` and an effective alarm that is false when disabled. Backend excludes disabled detector telemetry and permits configuration only to scoped staff. Dashboard uses existing command/result handling and displays the device-reported setting.

**Constraints:** MQ5/CO/particulate detection stays active. Fresh configurations default disabled; existing stored configurations missing the setting retain enabled behavior. Older firmware without `enabled` keeps existing ingestion semantics and gets no setting control. Do not expose tokens. Only canary-black receives OTA.

## Tasks
- [ ] Firmware: failing native tests for persisted enabled/disabled settings, legacy migration, disabled open input, MQTT validation/results; implement and run native checks; version 1.2.1.
- [ ] Backend: failing tests for disabled telemetry, legacy behavior, staff scope/resident prohibition, capability checks and exact MQTT topic/payload; implement and run backend suite.
- [ ] Dashboard: control on air sensor card showing confirmed status, staff-only, hidden on old firmware; use existing command pending/error/history states and EN/RO copy; build and verify in browser.
- [ ] Review integrated diff; build ESP32-S3 OTA image; deploy backend/dashboard; update only canary-black; disable unused detector through dashboard; clear Live incident and verify fresh heartbeats do not reopen it; verify database replication.

## Review focus
- Disabled detector cannot affect MQ5 detection.
- Existing connected detectors keep working after upgrade.
- Save failure cannot silently change persisted configuration.
- Residents cannot disable a detector through crafted requests.
- UI reports confirmed device state, including rejection and reboot persistence.

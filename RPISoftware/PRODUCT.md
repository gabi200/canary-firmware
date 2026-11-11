# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

The operations dashboard (`web/`, React) is the main design surface. The resident app
(`mobile/`, Flutter, Android + iOS) uses one shared custom theme on both systems rather
than each system's native design language.

## Users

Priority order when needs conflict (confirmed by the owner, 2026-11-10):

1. **Emergency dispatcher during an incident.** Reads the hazard source, live occupancy
   and the count of unaccounted residents under time pressure, then acts on the incident.
   This user wins conflicts.
2. **HOA manager** (Romanian *asociație de proprietari*), day to day. Checks sensor and
   building status and trends, and reacts when an incident appears.
3. **Technician / installer.** Commissions rooms and sensors, runs tests, pushes firmware,
   and needs the raw device data.
4. **Resident** (mobile app only). Receives the alarm, follows evacuation guidance and
   taps "I'm safe".

A system admin role sees everything.

## Product Purpose

Canary is a building-safety and hazard-response platform for multi-unit residential
buildings. It reads an in-building sensor network (combustible gas, CO, smoke and
particulates, water leak, presence) and drives one path:

**detection → alert → evacuation → victim-accounting**

Success means a dispatcher can tell, from the dashboard alone, where the hazard is and
who is still unaccounted for.

## Positioning

- Canary follows an incident past the alarm: it estimates occupancy and tracks which
  residents have checked in as safe.
- The dashboard shows both what each device reports (raw) and what the hub concludes
  from it (analysis). The mobile app shows analysis only.
- Everything runs on a Raspberry Pi hub inside the building, on the local network.

## Operating Context

- **Stage: competition prototype** (confirmed 2026-11-10). It is shown with simulators
  and a few real ESP32 sensors. It has not been validated on a physical Pi with the real
  sensors.
- A seeded demo building, `bld_007`, sits behind a Demo / Real switch in the top bar.
  Real sensors land in `bld_live` until moved to a zone.
- Dashboard views: Manager (`/manager`), Dispatch (`/dispatch`), Sensors (`/sensors`),
  Administration (rooms, devices, firmware, hub).
- Incidents, check-ins and sensor status arrive live over WebSocket.
- Optional three-Pi redundant hub; an AI HAT+ 2 generates the incident brief on demand
  (up to a minute), with a template fallback.

## Capabilities and Constraints

- English and Romanian, switched in the UI. Building data (zone labels, resident names,
  route steps) and machine ids are never translated.
- Role-gated routes, enforced again by the backend.
- The MQ5 gas value from real hardware is a raw ADC count, not ppm. Two units never share
  one chart axis.
- The hazard "source" is a rule-based triangulated zone with a confidence. Before an
  estimate exists it is the incident's first-detection zone.
- The hub never tells a resident who is home; occupancy is for managers, dispatchers and
  admins.
- Advisory system only: detection thresholds are illustrative engineering defaults, not
  certified life-safety setpoints. It does not replace certified detectors or emergency
  services.
- Login is username-only (dev token) and traffic is plaintext, so the hub is for a
  trusted LAN/VLAN.
- The hub sends no commands to devices yet. Push notifications (FCM/APNs) are wired but
  off by default.
- One open incident per hazard type per building.

## Brand Commitments

- Name: **Canary** (the README pairs it with 🐤).
- Dashboard title: "Canary — Operations".
- Shared hazard vocabulary across web and mobile: normal / warning / alarm / evacuation.

- Standing preference (owner, 2026-11-10): the dashboard is a conventional, professional,
  clean operations console. It should sit alongside Linear / Vercel and UniFi / Home
  Assistant in craft.
- Light and dark themes, with dark as the default.
- Hazard states keep their meaning: green / amber / red, the striped evacuation banner
  and the ISO safety pictograms.

## Evidence on Hand

- Seeded demo building `bld_007` with demo accounts (`ana`, `mihai`, `dispecer`,
  `tehnician`, `admin`).
- Firmware-accurate simulators (`simulator/hw_sim.py`, `building_sim.py`) with scenarios:
  normal, co, gas, smoke, leak, presence, offline, reboot.
- 95 backend tests; `scripts/smoke.sh`.
- Competition presentation: `../docs/prezentare/`.
- Contract and plan: `docs/HARDWARE.md`, `ARCHITECTURE.md`, `docs/DEMO.md`.

There are no real customers, deployments, testimonials, certifications or field results.
Future work must not invent any.

## Product Principles

1. **The incident comes first.** When an incident is open, hazard location and
   unaccounted people outrank every other piece of information.
2. **Show the reading and the conclusion.** Operators can always get from the hub's
   analysis back to the raw device values it came from.
3. **Say what the system does not know.** Offline or stale sensors, estimates and
   confidence levels are stated, never hidden behind a clean status.
4. **Advisory, not certified.** Nothing in the product may read as a certified
   life-safety guarantee.
5. **Residents' privacy holds.** Who is home is never shown to other residents.

## Accessibility & Inclusion

No standard has been set. Known needs: Romanian and English, and hazard states that stay
readable under stress.

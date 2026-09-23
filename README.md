# Canary firmware

Firmware and device software for Canary sensors and the Raspberry Pi hub.

| Project | Platform | Status |
| --- | --- | --- |
| [Water sensor](water_sensor/README.md) | ESP32-C3 | Implemented; physical-device validation pending |
| [Air sensor](air_sensor/README.md) | ESP32-S3 | Implemented; physical-device validation pending |
| [Hub](RPISoftware/README.md) | Raspberry Pi (64-bit OS, Docker) | Implemented in `RPISoftware/`; physical-device validation pending |

Each device lives in its own directory with its source, tests, build configuration,
and setup instructions. Add future sensors as sibling projects alongside
`water_sensor/`. Keep shared code in a common directory only when multiple
projects need it.

Both sensor projects expose the same API shape so one client can read either.
`GET /api/status` is unauthenticated and returns the whole device document.
Bearer-authenticated `POST` commands return that same document, and failures
use `{"error":"…","message":"…"}`. Browser OTA lives at `/update`, and the MQTT
topics are `<base>/availability`, `<base>/status`, `<base>/<actuator>/set` and
`<base>/command/result`. The fields inside the status document differ because
the hardware differs.

The Raspberry Pi hub in [`RPISoftware/`](RPISoftware/README.md) runs the Mosquitto
broker the sensors log in to (one MQTT user per sensor, named like its base topic),
reads `<base>/status` and `<base>/availability`, and serves a web dashboard and a
mobile app. It does not publish commands yet. Setup starts at
[`RPISoftware/RUNME.md`](RPISoftware/RUNME.md); the firmware ↔ hub contract is
[`RPISoftware/docs/HARDWARE.md`](RPISoftware/docs/HARDWARE.md).

Run the per-project checks from the repository root:

```sh
./water_sensor/scripts/run-native-tests.sh
./air_sensor/scripts/run-native-tests.sh
bash RPISoftware/scripts/smoke.sh   # hub: backend tests, web build, static infra checks
```

For firmware builds and device setup, follow each project's README and run its
commands from that project's directory. Tool downloads and compiled firmware are
local artifacts and are not tracked in Git.

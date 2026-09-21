# Canary firmware

Firmware and device software for Canary sensors and the Raspberry Pi hub.

| Project | Platform | Status |
| --- | --- | --- |
| [Water sensor](water_sensor/README.md) | ESP32-C3 | Implemented; physical-device validation pending |
| [Air sensor](air_sensor/README.md) | ESP32-S3 | Implemented; physical-device validation pending |
| [Hub](hub/README.md) | Raspberry Pi | Planned |

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

Run the per-project checks from the repository root:

```sh
./water_sensor/scripts/run-native-tests.sh
./air_sensor/scripts/run-native-tests.sh
```

For firmware builds and device setup, follow each project's README and run its
commands from that project's directory. Tool downloads and compiled firmware are
local artifacts and are not tracked in Git.

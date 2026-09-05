# Canary firmware

Firmware and device software for Canary sensors and the Raspberry Pi hub.

| Project | Platform | Status |
| --- | --- | --- |
| [Water sensor](water_sensor/README.md) | ESP32-C3 | Implemented; physical-device validation pending |
| [Hub](hub/README.md) | Raspberry Pi | Planned |

Each device lives in its own directory with its source, tests, build configuration,
and setup instructions. Add future sensors as sibling projects alongside
`water_sensor/`. Keep shared code in a common directory only when multiple
projects need it.

Run water-sensor checks from the repository root:

```sh
./water_sensor/scripts/run-native-tests.sh
```

For firmware builds and device setup, follow the water sensor README and run its
commands from `water_sensor/`. Tool downloads and compiled firmware are local
artifacts and are not tracked in Git.

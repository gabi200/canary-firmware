# Canary Raspberry Pi hub

The hub software lives in [`../RPISoftware`](../RPISoftware/README.md): Mosquitto
broker, FastAPI backend, web dashboard and Flutter app, deployed with Docker Compose
on 64-bit Raspberry Pi OS. Start with [`../RPISoftware/RUNME.md`](../RPISoftware/RUNME.md).
The firmware ↔ hub contract (MQTT topics, status documents, API) is
[`../RPISoftware/docs/HARDWARE.md`](../RPISoftware/docs/HARDWARE.md); checks and
troubleshooting are in [`../RPISoftware/DEBUG.md`](../RPISoftware/DEBUG.md). It has
not yet been validated on a physical Pi with the real sensors.

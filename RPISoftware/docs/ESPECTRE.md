# ESPectre Wi-Fi motion boards

Two dedicated boards (one ESP32-C3, one ESP32-S3) run the **stock ESPectre firmware** and report
Wi-Fi (CSI) motion over the hub's Mosquitto broker. The hub shows it to staff as per-room motion
evidence. It is not part of the Canary firmware, the alarm path or the occupancy count.

## Pinned release

ESPectre **3.0.0** (2026-10-07), the "native" standalone firmware, which has the MQTT contract below:

- ESP32-C3: `espectre-native-3.0.0-esp32c3.bin`
- ESP32-S3: `espectre-native-3.0.0-esp32s3.bin`

from <https://github.com/francescopace/espectre/releases/tag/3.0.0>. Flash and provision them with
ESPectre's own tools. Set the MQTT broker to the hub address (the VIP in three-Pi mode) and leave
the topic prefix at its default. Upgrading means re-checking the topic contract below, then changing
the version here.

## License and attribution

ESPectre is © Francesco Pace and licensed under the **GNU GPL v3.0** (the project also offers a
separate commercial licence). Canary does not include, link or redistribute any ESPectre code. The
boards run the unmodified upstream binaries, deployed separately, and the hub only reads their
MQTT messages. Anyone who redistributes the binaries with a Canary installation must comply with
the GPLv3, including providing the corresponding source (the upstream tag above).

## Topic contract (ESPectre 3.0.0 `docs/API.md`, not yet verified on our boards)

Base: `espectre/v1/devices/<device_id>`, where `device_id` is 16 lowercase hex characters derived
from the station MAC.

| Topic | Retained | Used fields |
|---|---|---|
| `<base>/motion` | no | `timestamp_ms` (board monotonic clock), `state` (`idle`/`motion`), `score` |
| `<base>/health` | yes (Last Will: offline) | `online`, `status` |
| `<base>/sensing` | yes | `ready`, `calibrating`, `threshold` |
| `<base>/device` | yes | `firmware` |

Other topics (`capabilities`, `wifi`, `ota`, `fault`, `commands/result`) are ignored. A retained
`motion` message is treated as stale and dropped.

## Hub configuration

```
CANARY_ESPECTRE_ZONES={"3cf79180d3a0aca4": "zone_kitchen", "a1b2c3d4e5f60718": "zone_bedroom"}
CANARY_ESPECTRE_TOPIC_PREFIX=espectre/v1/devices      # default
CANARY_ESPECTRE_STORE_INTERVAL_S=5                    # default
```

A board's id appears in the dashboard's Motion card ("Boards not placed in a room") as soon as it
publishes. Put that id in `CANARY_ESPECTRE_ZONES` and restart the backend. With the default
`CANARY_MQTT_SUBSCRIBE=#` nothing else is needed. With a narrower filter, the consumer also
subscribes to `<prefix>/+/motion|health|sensing|device`.

## What the hub does with it

- `app/ingestion/espectre.py` keeps one `motion_sensors` row per board (health, readiness,
  firmware, last seen, last motion). It stores motion in `motion_observations`: every state change,
  and an unchanged state at most every 5 s. Duplicates (QoS 1 redelivery) and out-of-order messages
  within one board boot are dropped. Observations are pruned with the other time series
  (`CANARY_RETENTION_DAYS`).
- `GET /api/v1/buildings/{id}/motion` (system_admin, hoa_manager, technician) returns each zone as
  `motion`, `no_recent_motion`, `calibrating`, `unavailable` (offline, silent for 60 s, or no
  health/sensing state yet) or `no_presence_sensor`, with the time of the last motion.
- Motion is never a `SensorType`, never a reading, never an `OccupancyEstimate` and never
  a person count. It doesn't touch the incident state machine or `SignatureFeatures.presence_frac`.
  As ESPectre's own docs put it, idle means no motion, not an empty room.

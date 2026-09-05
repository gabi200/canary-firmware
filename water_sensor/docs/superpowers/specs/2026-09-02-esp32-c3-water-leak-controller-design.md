# ESP32-C3 Water Leak Controller Design

## Purpose

Build an Arduino sketch for an ESP32-C3 that detects water with an analog resistive water-level sensor, closes a water-supply valve through a relay, sounds an active buzzer, reports its status over HTTP and MQTT, accepts authenticated control commands, and supports authenticated web-based OTA firmware updates.

The leak response must remain operational when Wi-Fi, MQTT, or the MQTT broker is unavailable.

## Hardware

### Water sensor

The selected sensor operates from 3 V to 5 V and produces an analog voltage that increases with the amount of water touching its 40 mm by 16 mm sensing area. It will be powered from 3.3 V so its output remains within the ESP32-C3 ADC input range.

Connections:

- Sensor `+` to ESP32-C3 `3V3`.
- Sensor `-` to ESP32-C3 `GND`.
- Sensor signal to the ADC pin selected in `HardwareConfig.h`.

This resistive sensor is prone to corrosion when left powered and exposed for long periods. Its dry output can also be indistinguishable from a disconnected signal wire. Those limitations will be documented and visible raw readings will be provided for installation checks.

### Relay and valve

The ESP32-C3 controls a relay module through one digital GPIO. It must not drive the valve coil directly. The initial relay polarity is active-HIGH, with a single compile-time setting to change it to active-LOW.

The firmware interprets an active relay as the command to close the water supply. The relay module, valve supply, flyback protection, and contact ratings must suit the actual valve.

If the valve requires an energized relay to stay closed, a total power failure will release the relay and may reopen the supply. Firmware cannot correct that hardware property. A normally-closed valve, latching valve, or backup supply is required when closure must survive a power failure.

### Active buzzer

The ESP32-C3 controls an active buzzer through one digital GPIO. A transistor driver is required when the buzzer's voltage or current exceeds the GPIO rating. The initial buzzer polarity is active-HIGH, with a compile-time setting to change it.

The buzzer uses a non-blocking on/off beep pattern while its alarm window is active. The default alarm duration is 180 seconds and is configurable through the captive portal. Buzzer timeout or manual silence affects sound only; it never clears the leak latch or opens the valve.

### Configurable pins

`HardwareConfig.h` will define:

- Analog sensor input pin.
- Relay output pin.
- Relay active level, defaulting to HIGH.
- Active-buzzer output pin and active level, defaulting to HIGH.
- Buzzer beep on/off timing.
- Optional configuration/reset button pin and its active level.

The README will identify the defaults and explain that ESP32-C3 development boards expose different pins.

## Firmware Architecture

The Arduino sketch is split into small modules with explicit responsibilities:

- `water_sensor.ino`: setup, main loop, scheduling, and service coordination.
- `HardwareConfig.h`: board-specific pins and electrical polarity.
- `LeakController`: filtered wet/dry state, debounce, safety latch, valve command rules, buzzer alarm state, and persistence transition signals.
- `ConfigStore`: nonvolatile configuration and persisted safety/valve state using ESP32 `Preferences`.
- `NetworkConfig`: Wi-Fi Manager captive-portal parameters and configuration lifecycle.
- `HttpApi`: status, valve control, firmware upload page, and OTA upload endpoint.
- `MqttService`: broker connection, last will, commands, state publication, and reconnect backoff.

Sensor evaluation and relay control do not depend on any networking component. All network work must return frequently to the main loop.

## Sensor Processing

The ADC is sampled on a fixed, non-blocking schedule. Several readings are averaged to reduce noise. The controller exposes both the latest raw average and the stable wet/dry state.

Two configurable thresholds provide hysteresis:

- At or above the wet threshold, the candidate state is wet.
- At or below the dry threshold, the candidate state is dry.
- Between thresholds, the current candidate state is retained.

The dry threshold must be lower than the wet threshold. A candidate state must persist for the configured debounce duration before the stable sensor state changes. Default thresholds are starting points only and must be calibrated using the installed sensor's dry and wet readings.

## Safety State Machine

### Startup

Firmware configures the relay output and commands the valve closed as early as practical. It then restores the persisted leak latch and requested valve state, while keeping the physical relay in the closed state. Only after valid sampling establishes a stable dry sensor state may a previously persisted open request be applied, and never when the restored leak latch is set.

### Leak detection

When the stable sensor state becomes wet:

1. Set the leak latch.
2. Command the relay to close the valve immediately.
3. Start or restart the buzzer alarm window.
4. Persist the changed latch and closed command.
5. Publish the changed status when network services are available.

The latch remains set when the sensor dries.

### Commands

A close command always commands the valve closed and persists that state.

An open command succeeds only when the sensor has established a stable dry state. A successful open command clears the leak latch, commands the valve open, persists both changes, and publishes status. An open request while wet, while sensor state is uninitialized, or during OTA is rejected.

HTTP and MQTT commands use this same command path so their safety behavior cannot diverge.

### Buzzer behavior

A new stable dry-to-wet transition starts the buzzer alarm, clears any previous silence or timeout state, and begins a fresh configured alarm window. During the window, the active buzzer follows the fixed non-blocking beep cadence from `HardwareConfig.h`.

An authenticated silence command stops the current sound and marks the alarm acknowledged. When the configured duration expires, sound stops and the alarm is marked timed out. Both conditions leave the leak latch and closed valve unchanged. A later dry-to-wet transition starts a new audible window regardless of the prior silence or timeout.

When the controller reboots with a persisted leak latch, it starts a fresh audible alarm window. Buzzer silence and elapsed alarm time are intentionally not persisted, so a power cycle cannot permanently suppress the warning.

### Flash wear

State is written only when a persisted value changes. Periodic samples and heartbeat publications do not write flash.

## Configuration Portal

WiFiManager supplies the initial access point and captive portal. It opens when no Wi-Fi credentials exist. A documented configuration-button action at boot will allow the portal to be reopened.

The portal collects:

- Device name.
- MQTT enabled/disabled state.
- Broker host and port.
- MQTT username and password.
- MQTT base topic.
- HTTP API token.
- Wet and dry ADC thresholds.
- Wet/dry debounce duration.
- Buzzer alarm duration in seconds, defaulting to 180 seconds.

Wi-Fi credentials are managed by WiFiManager. Custom values are validated and stored in `Preferences`. Secrets are never printed to Serial or returned by the status API.

The API token is mandatory. MQTT may be disabled by leaving its host empty or through its enabled setting.

## HTTP API

The server returns JSON errors with a stable `error` key and a human-readable `message`.

### `GET /api/status`

No authentication is required. Returns:

- Device name and firmware version.
- Uptime.
- Raw/filtered sensor ADC value.
- Stable sensor state and whether it has initialized.
- Wet and dry thresholds.
- Leak latch state.
- Commanded valve state and physical relay output state.
- Buzzer sounding, silenced, and timed-out state, plus remaining alarm time.
- Wi-Fi connection state and signal strength.
- MQTT enabled and connection state.
- OTA-in-progress state.

No credentials or tokens are returned.

### `POST /api/valve`

Requires `Authorization: Bearer <token>` and a JSON body containing either `{"state":"open"}` or `{"state":"closed"}`.

- Success returns the updated state.
- Invalid JSON or a missing state returns `400 Bad Request`.
- Missing or invalid credentials return `401 Unauthorized`.
- An open request rejected by the safety state returns `409 Conflict`.

### `GET /update`

Serves a small firmware-upload page. The page asks for the API token and firmware `.bin`, then uses JavaScript to stream the upload request with the bearer token. It does not store the token.

### `POST /api/buzzer`

Requires `Authorization: Bearer <token>` and a JSON body containing `{"command":"silence"}`. A valid request stops the current buzzer window without changing the leak latch or valve state. Invalid JSON or commands return `400 Bad Request`; missing or invalid credentials return `401 Unauthorized`.

### `POST /api/ota`

Requires the bearer token and a firmware upload. At upload start the controller:

1. Marks OTA active so open commands are rejected.
2. Commands and persists the valve closed.
3. Streams firmware chunks into the ESP32 OTA partition with the Arduino `Update` API.

Malformed uploads, insufficient update space, write failures, and final verification failures return an error and retain the currently bootable firmware. A successful upload returns success and reboots the controller. The valve remains commanded closed after reboot until explicitly reopened under dry conditions.

The partition scheme must include two application slots suitable for OTA.

HTTP is unencrypted. The controller is intended for a trusted LAN or isolated IoT VLAN; the API token can be observed by a hostile device on the same network. HTTPS and certificate management are outside this version.

## MQTT Interface

MQTT is optional. The client uses broker credentials from the portal, a unique client ID derived from the configured device name and chip identity, and a last-will message.

Topics under the configured base topic:

- `<base>/availability`: retained `online` or `offline`; `offline` is the last will.
- `<base>/status`: retained JSON matching the relevant HTTP status fields.
- `<base>/valve/set`: command topic accepting case-insensitive `OPEN` or `CLOSE`.
- `<base>/buzzer/set`: command topic accepting case-insensitive `SILENCE`.
- `<base>/command/result`: command outcome JSON, including rejection reasons.

Status is published immediately on state changes and periodically as a heartbeat. Commands are never accepted by subscribing to the retained state topic. A retained command received on `valve/set` is processed according to the same safety rules, though documentation will recommend non-retained command publications.

MQTT authentication relies on broker username/password and network isolation; the HTTP bearer token is not used as an MQTT payload secret.

## Resilience and Error Handling

- Sensor sampling and relay control continue during all network outages.
- Wi-Fi and MQTT reconnect attempts use increasing, capped backoff without `delay()` loops.
- Invalid portal values retain safe defaults and produce Serial diagnostics without exposing secrets.
- Failure to connect to MQTT never blocks HTTP or sensor handling.
- OTA failures keep the valve closed and leave the prior firmware bootable.
- Authentication comparisons avoid early-exit character comparison where practical.
- All API buffers and MQTT payload sizes are bounded for ESP32-C3 memory.
- Serial messages describe state transitions and failures, not credentials.

## Dependencies

The implementation uses:

- Arduino ESP32 core, including `WiFi`, `WebServer`, `Preferences`, and `Update`.
- WiFiManager for captive-portal provisioning.
- PubSubClient for MQTT.
- ArduinoJson for bounded JSON parsing and generation.

Exact compatible dependency versions will be documented in `platformio.ini` and the README. The sketch remains usable from Arduino IDE after installing the three external libraries.

## Verification

Pure safety logic will be kept independent enough for native automated tests. Tests cover:

- Wet and dry threshold hysteresis.
- Debounce behavior and noise rejection.
- Leak latch activation.
- Dry sensor not automatically clearing the latch.
- Manual close.
- Rejection of open while wet or uninitialized.
- Successful open and latch clearing while dry.
- Restored persistent leak/valve state.
- OTA state rejecting open commands.
- Active-HIGH and active-LOW relay mapping.
- Active-buzzer beep cadence without blocking sensor processing.
- Manual buzzer silence without changing the latch or valve.
- Automatic buzzer timeout at the configured duration.
- A later dry-to-wet transition restarting a silenced or timed-out alarm.
- A restored leak latch starting a fresh alarm after reboot.

The full sketch will be compiled for an ESP32-C3 target with an OTA-capable partition layout.

The README hardware checklist will cover:

1. Verify dry and wet ADC readings and configure thresholds between them.
2. Confirm relay polarity before connecting the valve.
3. Confirm boot and reset behavior commands the safe state.
4. Confirm a wet sensor closes and latches the valve without Wi-Fi or MQTT.
5. Confirm HTTP and MQTT open requests are rejected while wet.
6. Confirm dry alone does not reopen the valve.
7. Confirm authenticated dry-open works and persists.
8. Confirm invalid tokens cannot mutate valve state or upload firmware.
9. Confirm a valid OTA update closes the valve and reboots into the new firmware.
10. Confirm broker loss and recovery update MQTT availability and state.
11. Confirm buzzer silence and timeout never clear the leak latch or open the valve.
12. Confirm a new dry-to-wet transition restarts the audible alarm.

## Explicitly Deferred

- HTTPS and device certificate provisioning.
- Home Assistant MQTT discovery.
- Arduino IDE `ArduinoOTA` uploads.
- Cloud service integration.
- Multiple users or role-based authorization.
- Automatic valve reopening.
- Reliable electrical detection of a disconnected resistive sensor.

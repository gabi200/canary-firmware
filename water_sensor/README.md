# ESP32-C3 water leak controller

Firmware for an ESP32-C3 that watches an analog resistive water sensor, closes
a relay-controlled water valve on a stable wet reading, and sounds an active
buzzer. It provides a local HTTP API, optional MQTT, a WiFiManager provisioning
portal, and authenticated browser-based OTA firmware updates.

Safety processing is local: sensor sampling, leak latching, valve control, and
the buzzer do not depend on Wi-Fi, MQTT, or a reachable broker. This is not a
replacement for appropriately rated plumbing, electrical protection, or a
physical emergency shutoff.

## Important safety limits

- The relay output means **close the water supply**. A wet event latches the
  valve closed. Drying the sensor does not open it; an authenticated open
  command is required after a stable dry state.
- The relay output drives a **relay-module input only**. Do not power a valve
  coil from an ESP32-C3 pin.
- If the selected valve needs an energized relay to remain closed, a total
  power loss releases the relay and **may reopen the water supply**. Firmware
  cannot prevent that. Use a normally-closed or latching valve, or a suitable
  backup supply, when closure must survive loss of power.
- HTTP and OTA are unencrypted. MQTT uses the plaintext `WiFiClient` transport
  with no TLS. Use HTTP, OTA, and MQTT only on a trusted LAN or isolated IoT
  VLAN: a hostile device on that network can observe the HTTP bearer token and
  MQTT broker credentials, commands, and status. HTTPS, MQTT TLS, certificate
  provisioning, cloud integration, and Arduino IDE `ArduinoOTA` uploads are
  outside this version.
- A resistive sensor can corrode if powered and exposed for extended periods.
  A disconnected signal and a dry sensor can both read near zero, so this
  firmware cannot reliably distinguish those conditions.

## Hardware and wiring

`HardwareConfig.h` contains the board-specific defaults. Check that each pin is
actually exposed and suitable on the particular ESP32-C3 board before wiring;
GPIO9 is a boot-strapping pin on ESP32-C3 and must not be used for a button
held low during reset. GPIO10 is the boot/config button input on this design.

| Function | Default GPIO | Default configuration |
| --- | ---: | --- |
| Analog water-sensor signal | GPIO0 | 12-bit ADC input |
| Relay-module input | GPIO4 | `RELAY_ACTIVE_HIGH = true` |
| Active-buzzer driver | GPIO5 | `BUZZER_ACTIVE_HIGH = true` |
| Boot/config button | GPIO10 | `CONFIG_BUTTON_ACTIVE_LOW = true`, `INPUT_PULLUP` |

Wire the sensor `+` to the board `3V3`, sensor `-` to board `GND`, and sensor
signal to GPIO0. Power the sensor at 3.3 V so its analog output is within the
ESP32-C3 ADC range. The sensor, ESP32-C3, relay-module logic input, and any
driver circuits need a shared ground.

Connect GPIO4 only to a relay module's logic input. Supply the relay module and
valve from correctly sized supplies. The relay contacts, wiring, fuse/protection,
and valve supply must be rated for the valve's actual voltage, current, and
inrush. If using a raw relay coil rather than a relay module, use a transistor
driver and a flyback diode; do not connect the coil to GPIO4.

GPIO5 is intended for an active buzzer or its driver. Use a transistor driver
when the buzzer voltage or current exceeds the ESP32-C3 GPIO limits. A raw
inductive buzzer/load also needs suitable flyback suppression. The compiled
defaults make a HIGH level active for both relay and buzzer; change
`RELAY_ACTIVE_HIGH` or `BUZZER_ACTIVE_HIGH` only after confirming the actual
hardware polarity.

The controller drives the relay active early during boot, which is its commanded
closed state. Verify relay polarity with the valve disconnected before plumbing
is connected.

## Build and upload

The checked setup was built with Arduino CLI 1.5.1, ESP32 core 3.3.11,
ArduinoJson 7.4.3, PubSubClient 2.8, and WiFiManager 2.0.17. The repository
includes `arduino-cli.yaml` for the Espressif board-index URL and uses the
normal Arduino data and sketchbook directories for installed cores and libraries.

### Arduino CLI

Use `arduino-cli` from `PATH`, or the project-local `./.tools/arduino-cli` when
present. On a fresh setup, install the declared versions:

```bash
./.tools/arduino-cli core update-index --config-file arduino-cli.yaml
./.tools/arduino-cli core install esp32:esp32@3.3.11 --config-file arduino-cli.yaml
./.tools/arduino-cli lib install ArduinoJson@7.4.3 PubSubClient@2.8 WiFiManager@2.0.17 --config-file arduino-cli.yaml
./.tools/arduino-cli compile --config-file arduino-cli.yaml \
  --fqbn esp32:esp32:esp32c3:PartitionScheme=default,CDCOnBoot=cdc \
  --warnings all --output-dir build .
```

The `default` partition selection is required because OTA needs two suitable
application slots. Upload with the serial port and baud rate appropriate for
the board, for example (replace the port):

```bash
./.tools/arduino-cli upload --config-file arduino-cli.yaml \
  --fqbn esp32:esp32:esp32c3:PartitionScheme=default,CDCOnBoot=cdc \
  --port /dev/ttyACM0 --input-dir build .
```

### Arduino IDE

1. Add `https://espressif.github.io/arduino-esp32/package_esp32_index.json` to
   **Preferences → Additional Boards Manager URLs**.
2. Install **esp32 by Espressif Systems** version 3.3.11 from Boards Manager.
3. Install these Library Manager versions: ArduinoJson 7.4.3, PubSubClient 2.8,
   and WiFiManager 2.0.17.
4. Open this directory as the `water_sensor` sketch, select an ESP32-C3 board
   matching the hardware, select the **default** OTA-capable partition scheme,
   set **USB CDC On Boot** to **Enabled**, then compile/upload. Review
   `HardwareConfig.h` before the first upload. Startup diagnostics and the
   five-second status heartbeat use the USB serial monitor at 115200 baud.

## Provisioning, configuration, and recovery

On first run, or when no usable Wi-Fi configuration exists, the device opens a
WiFiManager captive portal named `<device-name>-setup`; with default settings
that is `water-sensor-setup`. Join that access point and complete the portal.
The API token is mandatory and must be 12–64 characters. MQTT is optional; set
MQTT enabled to `1` and provide a broker host to use it, or leave it disabled.

Portal fields are device name, MQTT enabled/host/port/user/password/base topic,
API token, wet/dry thresholds, debounce milliseconds, and alarm seconds. The
defaults are MQTT disabled, port 1883, base topic `water-sensor`, wet threshold
1200, dry threshold 600, debounce 1000 ms, and alarm duration 180 seconds.
Stored passwords and tokens are not rendered back into the portal: leave a
secret field blank to retain its existing value. Invalid initial submissions
restart the portal rather than saving an incomplete configuration.

To reopen provisioning later, hold the configured boot/config button while the
device starts. With the shipped defaults, GPIO10 is active-low and uses the
internal pull-up, so hold the button to GND during boot. Do not assume another
board's BOOT button is wired identically without checking it.

### Calibrate the sensor

Read the live ADC value from the unauthenticated status endpoint:

```bash
curl -sS http://$DEVICE_IP/api/status | jq '.sensor'
```

Record multiple readings with the installed sensor dry and immersed at the
location where it will be used. Choose `dry_threshold` below `wet_threshold`,
with separation for observed noise. For example, dry `180` and immersed `1680`
can be configured as dry threshold `400` and wet threshold `1000`. These are
an example only, not universal values. Recheck periodically for corrosion or
changes in the installation, and treat a near-zero reading as ambiguous
(dry or disconnected) until the wiring is inspected.

## HTTP API

The following names are metavariables used throughout this guide:

```bash
export DEVICE_IP=192.0.2.10
export BROKER=broker.example.invalid
```

`DEVICE_IP`, `API_TOKEN`, `BROKER`, `USER`, and `PASS` are documentation
metavariables. The sample IP and broker names are documentation-only values.
`API_TOKEN` is the portal token; `USER` and `PASS` are MQTT broker credentials.

### Finding the device without its IP

The address DHCP hands out can change, so the device also answers by name over
mDNS once it joins Wi-Fi. The host name is the configured device name lowercased,
with every run of characters other than letters and digits turned into one
hyphen (`water-sensor` by default, `canary-water` if nothing usable remains). Use
`http://<name>.local` wherever this guide says `$DEVICE_IP`, for example
`export DEVICE_IP=water-sensor.local`. Every Canary sensor also advertises a
`_canary._tcp` service on port 80 with TXT records `type=water`, `fw` and
`api=/api/status`, so a client can list all sensors with
`avahi-browse -rt _canary._tcp` (Linux) or `dns-sd -B _canary._tcp` (macOS)
instead of storing addresses. Give each device a unique name so the `.local`
names do not collide.

Do not put `API_TOKEN` or `PASS` in a shell command, shell history, source
control, or a `mosquitto_* -P` argument: command arguments can be exposed to
other local processes. Put secrets in permission-restricted client option files
instead (for example, mode 0600 files in a user configuration directory), or
retrieve them from the local secret-management method approved for the
installation. A protected file reduces local accidental exposure; it does not
encrypt the plaintext network protocols.

For example, create these files with the actual values using a protected editor
or secret-management workflow, then restrict each file to its owner:

```text
# ~/.config/water-sensor/http-curl.conf (mode 0600)
header = "Authorization: Bearer <API_TOKEN>"

# ~/.config/water-sensor/mosquitto.conf (mode 0600)
-h <BROKER>
-u <USER>
-P <PASS>
```

The `-P` setting is safe from command-line process inspection only because it
is inside the protected Mosquitto option file, not an argument to
`mosquitto_pub` or `mosquitto_sub`. Set the non-secret option-file paths once:

```bash
export HTTP_CURL_CONFIG="$HOME/.config/water-sensor/http-curl.conf"
export MQTT_OPTIONS="$HOME/.config/water-sensor/mosquitto.conf"
```

All mutating HTTP endpoints require the configured `Authorization: Bearer
<API_TOKEN>` header.

### `GET /api/status`

This endpoint is unauthenticated and returns no credentials. Its JSON object
has every field below:

| Object/field | Meaning |
| --- | --- |
| `device.name`, `device.firmware` | Configured device name and compiled firmware version |
| `uptime_ms` | Milliseconds since boot |
| `sensor.adc` | Latest averaged 12-bit ADC reading |
| `sensor.initialized`, `sensor.state` | Stable-sensor readiness and `uninitialized`, `dry`, or `wet` |
| `sensor.wet_threshold`, `sensor.dry_threshold` | Configured hysteresis thresholds |
| `leak_latched` | Whether a wet event remains latched |
| `valve.requested`, `valve.applied`, `valve.relay_active` | Requested/present valve state (`open` or `closed`) and relay active state |
| `alarm.state`, `alarm.sounding`, `alarm.remaining_seconds` | `inactive`, `sounding`, `silenced`, or `timed_out`; sound state and remaining window |
| `wifi.connected`, `wifi.rssi` | Wi-Fi state and RSSI (0 when disconnected) |
| `wifi.ip` | IPv4 address while Wi-Fi is connected (absent otherwise; firmware 1.1.0+). The hub suggests it as the firmware push address |
| `mqtt.enabled`, `mqtt.connected` | MQTT configuration and current connection state |
| `ota.in_progress` | Whether an authenticated OTA update is active |

```bash
curl -sS http://$DEVICE_IP/api/status | jq .
```

### `POST /api/valve` and `POST /api/buzzer`

Valve payloads are `{"state":"open"}` or `{"state":"closed"}`. Buzzer
payloads are `{"command":"silence"}`. A successful request returns the same
status document as `GET /api/status`.

```bash
# Expected 401: authentication is required even to close the valve remotely.
curl -i -X POST http://$DEVICE_IP/api/valve \
  -H 'Content-Type: application/json' -d '{"state":"closed"}'

curl -i -X POST http://$DEVICE_IP/api/valve \
  --config "$HTTP_CURL_CONFIG" \
  -H 'Content-Type: application/json' -d '{"state":"closed"}'

curl -i -X POST http://$DEVICE_IP/api/valve \
  --config "$HTTP_CURL_CONFIG" \
  -H 'Content-Type: application/json' -d '{"state":"open"}'

curl -i -X POST http://$DEVICE_IP/api/buzzer \
  --config "$HTTP_CURL_CONFIG" \
  -H 'Content-Type: application/json' -d '{"command":"silence"}'
```

Opening is accepted only after the sensor has established stable dry state;
drying alone never opens the valve. A close is always accepted. Silencing or
timing out the buzzer never clears the latch or opens the valve. A later
dry-to-wet transition starts a fresh alarm window.

Errors use `{"error":"…","message":"…"}` (the emergency serialization
fallback is `{"error":"internal_error"}`). The implemented error keys are:

| HTTP status | `error` key | Situation |
| ---: | --- | --- |
| 400 | `invalid_request` | Malformed request, missing/invalid command, or required `Content-Length` absent |
| 401 | `unauthorized` | Missing or invalid bearer token |
| 404 | `not_found` | Unknown route |
| 409 | `sensor_wet` | Open requested while sensor is wet |
| 409 | `sensor_uninitialized` | Open requested before stable dry state |
| 409 | `ota_active` | Open requested during OTA, or another OTA is active |
| 413 | `payload_too_large` | Valve/buzzer request body exceeds 128 bytes |
| 431 | `headers_too_large` | Request headers exceed the parser limit |
| 500 | `status_unavailable` | Status JSON could not be produced |
| 500 | `ota_failed` | Firmware upload failed; message gives the bounded update error |
| 500 | `internal_error` | Emergency error-serialization fallback |

## MQTT (optional)

Configure MQTT in the portal before use. The client uses the configured broker
credentials, not the HTTP bearer token. It connects with a device-derived client
ID, sends a retained last will of `offline`, publishes retained `online` after
reconnection, and publishes retained status on state changes (including the
one-time alarm-timeout transition) and at least every 60 seconds. It uses
plaintext `WiFiClient` MQTT with no TLS: broker credentials,
commands, and status need the same trusted-LAN or isolated-IoT-VLAN protection
as HTTP and OTA.

With configured base topic `<base>` (the default is `water-sensor`), these are
all MQTT topics:

| Topic | Direction and retention | Payload |
| --- | --- | --- |
| `<base>/availability` | Device publish, retained | `online`; last-will `offline` |
| `<base>/status` | Device publish, retained | The same status JSON fields listed above |
| `<base>/valve/set` | Device subscription, QoS 1 | Case-insensitive `OPEN` or `CLOSE` |
| `<base>/buzzer/set` | Device subscription, QoS 1 | Case-insensitive `SILENCE` |
| `<base>/command/result` | Device publish, not retained | Command-result JSON below |

Publish commands as **non-retained** messages. Retaining an MQTT command can
cause it to be processed after a later reconnect; retained status and
availability are intentional, retained commands are not.

Command results have either `{"command":"OPEN|CLOSE|SILENCE","accepted":true,"state":"open|closed|silenced"}`
or `{"command":"…","accepted":false,"error":"…"}`. Error values are
`invalid_command`, `busy`, `sensor_wet`, `sensor_uninitialized`, `ota_active`,
`persistence_failed`, `alarm_inactive`, `command_rejected`, or
`status_serialization_failed` (for the internal `STATUS` result). MQTT payloads
never contain the HTTP API token.

```bash
mosquitto_sub -o "$MQTT_OPTIONS" -v -t 'water-sensor/#'
mosquitto_pub -o "$MQTT_OPTIONS" \
  -t 'water-sensor/valve/set' -m CLOSE
mosquitto_pub -o "$MQTT_OPTIONS" \
  -t 'water-sensor/buzzer/set' -m SILENCE
mosquitto_pub -o "$MQTT_OPTIONS" \
  -t 'water-sensor/valve/set' -m OPEN
```

Replace `water-sensor` in those topic arguments when a different base topic is
configured. The commands above omit `-r` deliberately.

### ESP-NOW backup link

When a node has MQTT enabled but loses its MQTT session (usually because its
Wi-Fi dropped), it keeps sending its status document over ESP-NOW instead, on
every change and every 60 seconds. Every node listens. A node with a live
MQTT session republishes what it hears on `<origin base>/status` (retained),
exactly as the origin would have; a node without one rebroadcasts it, up to 3
times, so a frame can hop across several offline nodes. Water and air nodes
relay each other. The hub needs no change: a live status marks the origin
online again after its last will.

- **Status only.** Hub commands and command results do not travel over the
  mesh. The local safety logic does not need the network.
- **Needs a node that still has MQTT.** If the access point itself is down for
  every node, the mesh has nowhere to deliver.
- **Channel.** ESP-NOW works only on one channel. About 20 seconds into an
  outage the node stops the core's back-to-back reconnect scans, holds the
  access point's last channel (where its neighbours are), and tries Wi-Fi
  again every 30 seconds. It must have joined Wi-Fi once since boot to know
  that channel; a node that boots into an outage does not use the mesh.
- **Signed, not encrypted.** Frames carry a 16-byte HMAC-SHA256 tag keyed from
  the Wi-Fi passphrase (WPA2 PBKDF2, so a captured frame is no easier to
  brute-force than a captured handshake), plus a boot counter kept in NVS and a
  sequence number. Relays drop unsigned, altered and replayed frames. Anyone in
  radio range can read the status, as with plaintext MQTT. Open Wi-Fi
  networks disable the mesh.
- **Power.** Wi-Fi modem sleep is turned off so the receiver hears
  neighbours between beacons.

## Web OTA

Build with the OTA-capable partition command shown above. Open
`http://$DEVICE_IP/update` in a browser, enter the API token and choose the
compiled firmware `.bin`. The page does not store the token. From the hub, use
the dashboard's **Administration → Firmware** tab: pin the device's IP address
and API token once, then send `build/water_sensor.ino.bin` to one or many sensors
(the hub uploads to this same `/api/ota`, one device at a time, and confirms
the version the device reports after its reboot;
[`RPISoftware/docs/HARDWARE.md`](../RPISoftware/docs/HARDWARE.md) §4, Firmware).
Devices on 1.0.0 do not report `wifi.ip`: type the address. Alternatively:

```bash
# Expected 401 and no write: missing Authorization header.
curl -i -X POST -H 'Expect:' -F 'firmware=@build/water_sensor.ino.bin' \
  http://$DEVICE_IP/api/ota

# Expected OTA error and a closed valve: deliberately not a firmware image.
curl -i -X POST --config "$HTTP_CURL_CONFIG" -H 'Expect:' \
  -F 'firmware=@docs/superpowers/specs/2026-09-02-esp32-c3-water-leak-controller-design.md' \
  http://$DEVICE_IP/api/ota

# Expected success response: {"ok":true,"rebooting":true}.
curl -i -X POST --config "$HTTP_CURL_CONFIG" -H 'Expect:' \
  -F 'firmware=@build/water_sensor.ino.bin' http://$DEVICE_IP/api/ota
```

`-H 'Expect:'` stops curl from pausing about a second before a large upload to
wait for a `100 Continue` reply the firmware does not send; without it the
device's 1-second idle limit fails the upload with `Firmware upload timed out`.

The OTA request authenticates before writes begin. It forces and persists the
valve closed, blocks valve-open requests during upload, and reboots after a
successful response. A failed upload leaves the prior bootable firmware in
place and leaves the valve commanded closed. Recheck `/api/status` after the
reboot before issuing any open command.

## Deferred capabilities

- HTTPS, MQTT TLS, device certificate provisioning, cloud integration, and
  Arduino IDE `ArduinoOTA` uploads.
- Home Assistant MQTT discovery.
- Multiple users or role-based authorization.
- Automatic valve reopening and reliable electrical detection of a disconnected
  resistive sensor.

## Hardware verification checklist (perform on the installed system)

This checklist is intentionally not marked as completed by the repository.
Record the observed results and installation details below only after testing
the actual board, sensor, relay, and valve.

- [ ] Record dry and wet ADC readings; set thresholds between them and confirm
  stable dry/wet transitions after the configured debounce period.
- [ ] With the valve disconnected, confirm relay polarity: GPIO4 active means
  the intended valve-close command. Then confirm relay contacts and wiring are
  rated for the installed valve.
- [ ] Confirm boot and reset command the safe, closed state before normal
  sensor initialization.
- [ ] Disconnect Wi-Fi/MQTT and confirm a wet sensor still closes and latches
  the valve.
- [ ] While wet, confirm HTTP and MQTT open requests are rejected.
- [ ] Confirm dry sensor state by itself does not clear the latch or reopen the
  valve.
- [ ] From stable dry state, confirm an authenticated HTTP dry-open succeeds
  and its requested state persists across restart.
- [ ] Confirm missing/invalid bearer tokens cannot mutate the valve, silence
  the buzzer, or upload firmware.
- [ ] Confirm buzzer silence and alarm timeout stop sound only; neither clears
  the leak latch nor opens the valve.
- [ ] After silence or timeout, make a dry-to-wet transition and confirm the
  audible alarm starts again.
- [ ] Confirm a valid OTA image first closes the valve, then reboots into the
  intended firmware version; confirm failure leaves the valve closed.
- [ ] With the broker still running, disconnect the device abruptly and confirm
  its retained MQTT last will reports `offline`; then reconnect the device and
  confirm retained `online` and current status. Test broker loss/recovery
  separately: after the broker returns, the device must reconnect and publish
  its current retained availability and status.
- [ ] With a second node online nearby, take this node off Wi-Fi (block its
  MAC on the access point) and confirm its status keeps reaching the broker on
  `<base>/status` within one heartbeat after the 20-second fallback starts.
  Unblock it and confirm it rejoins Wi-Fi within about 30 seconds.

### Installation record template

Keep this record with the deployment (or in a private deployment note if it
would reveal sensitive site details). Do not replace blank values with guesses.

```text
Date (ISO 8601):
Installer:
Site / asset identifier (non-secret):

Board model:
Firmware version (from /api/status):
Sensor model / placement:
Valve type and rated voltage/current:
Relay module and contact rating:
Relay active level verified (HIGH/LOW):
Buzzer/driver and active level verified (HIGH/LOW):

Observed dry ADC range:
Observed wet ADC range:
Configured dry threshold:
Configured wet threshold:
Configured debounce (ms):
Configured alarm duration (s):

Checklist exceptions / corrective actions:
Tested by:
Completion date (ISO 8601):
```

## Development checks

Run the native safety tests:

```bash
scripts/run-native-tests.sh
```

For the embedded warning-clean build, use the Arduino CLI compile command in
the build section. Native tests exercise the platform-neutral safety state
machine, configuration validation, authentication, persistence retry behavior,
MQTT command/connection behavior, and the ESP-NOW backup link's frame format,
signing, replay protection and MQTT fallback/relay; they do not substitute for
the installed hardware checklist.

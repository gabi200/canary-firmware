# ESP32-S3 air quality and hazard monitor

Firmware for an ESP32-S3 that watches carbon monoxide, combustible gas, and
particulate levels, grades each channel against configurable thresholds, and
signals hazards on an RGB LED and an active buzzer, plus an optional SSD1306
OLED. It also reports temperature, humidity, and radar presence. It provides a local HTTP API,
optional MQTT, a WiFiManager provisioning portal, and authenticated
browser-based OTA firmware updates.

Hazard processing is local: sensor parsing, channel grading, the alarm state
machine, the LED, and the buzzer do not depend on Wi-Fi, MQTT, or a reachable
broker. This is a monitoring and early-warning aid. It is not a certified
alarm and does not replace one.

## Important safety limits

- **This is not a certified CO alarm, gas detector, or smoke alarm, and must
  not be used as a replacement for one.** Certified alarms are tested to
  published response curves, alarm thresholds, and end-of-life behavior; this
  firmware and these sensor modules are not. Install listed, certified alarms
  for life safety and treat this device as an additional early-warning and
  logging aid.
- **The LED uses GPIO21 (red), GPIO47 (green), and GPIO48 (blue).** These
  avoid GPIO35, GPIO36, and GPIO37, which carry the extra data lines of an
  in-package Octal SPI PSRAM. On any module whose suffix is `R8` or `R16V`
  (N4R8, N8R8, N16R8, N16R16VA, and every WROOM-2), those three pins are wired
  to the PSRAM and are not usable, even though the DevKitC-1 silkscreen exposes
  them on header J3; `analogWrite()` to them returns normally and drives
  nothing, with no light and no error. Every Espressif-branded
  ESP32-S3-DevKitC-1 SKU ships with Octal PSRAM, so the compiled pins work on
  those boards and on modules with Quad PSRAM or none. `HardwareConfig.h` keeps
  the older GPIO37/36/38 set commented out; use it only on a module without
  Octal PSRAM (N4, N8, N16, N4R2, N8R2, N16R2), and confirm the PSRAM type from
  the part number on the module shield and the core's boot log first.
- GPIO48 also drives the onboard addressable RGB LED on DevKitC-1 v1.0, so on
  that board revision the discrete blue LED shares its pin with the onboard
  one (v1.1 moved the onboard LED to GPIO38). On `R16V` modules GPIO47 and
  GPIO48 switch at 1.8 V instead of 3.3 V, so size the LED series resistors or
  add a driver accordingly.
- GPIO39 is MTCK and has a weak internal pull-up enabled at reset. An
  active-high buzzer stage can therefore chirp from power-on until `setup()`
  drives the pin low. Add an external pull-down resistor at the driver input
  if that chirp is unwanted.
- **The MQ5 needs a divider on its analog output.** Its heater runs at 5 V and
  the AO can swing to roughly 5 V, which would damage a 3.3 V ADC pin. A
  divider is mandatory, not optional. At the default 11 dB attenuation the
  ESP32-S3 ADC only resolves about 0–2.9 V, not 0–3.3 V, and anything above
  that reads as full scale, so size the divider for 2.5 V or less at the
  sensor's full-scale output. The MQ5 is also not gas-selective: it responds
  to LPG, methane, propane, alcohol vapour, and smoke, and it needs a long
  burn-in (24–48 hours for a new element) plus per-installation threshold
  calibration. The value this firmware reports is a raw 12-bit ADC count, not
  a ppm figure and not a %LEL figure.
- **The build requires "USB CDC On Boot: Enabled".** UART0 is wired to the CO
  sensor, so the console must move to the native USB port. `HardwareConfig.h`
  carries an `#error` guard that fails the build otherwise; without it the
  sketch would compile with `Serial` bound to UART0 and the CO channel would
  never produce a reading. The ESP32-S3 has only three hardware UARTs, and all
  three are used here.
- The ZE03-CO needs at least 5 minutes of warm-up before its output is
  meaningful, and Winsen suggests about 24 hours of aging after a long
  power-off. Its supply is 5 V with 3 V TTL signal levels, so do not feed its
  TX line into a pin expecting 5 V logic or drive its RX from a 5 V source.
- HTTP and OTA are unencrypted. MQTT uses the plaintext `WiFiClient` transport
  with no TLS. Use HTTP, OTA, and MQTT only on a trusted LAN or isolated IoT
  VLAN: a hostile device on that network can observe the HTTP bearer token and
  MQTT broker credentials, commands, and status. HTTPS, MQTT TLS, certificate
  provisioning, cloud integration, and Arduino IDE `ArduinoOTA` uploads are
  outside this version.
- **Alarms are level-based, not latched.** Unlike the water sensor's valve, a
  hazard here clears by itself: once the channel reads below its danger
  threshold continuously for the 30-second clear hold, the alarm stops. No
  acknowledgement is required and none is recorded. Peak readings are kept in
  RAM only and reset on restart; configuration is the only persisted state.
- **A faulted sensor does not sound the buzzer.** A UART sensor that stops
  producing valid frames for 15 seconds is graded `fault`, which turns the LED
  cyan and is reported in the API, but it is deliberately silent. This is a
  known limitation and a deliberate trade: audible nuisance alarms get devices
  unplugged. A dead CO sensor therefore looks like quiet, healthy air to
  anyone who only listens. Monitor `co.valid`, `particulate.valid`, and the
  channel `state` fields, or the retained MQTT status topic, if the
  installation depends on the sensors still being alive.
- GPIO0 is an ESP32-S3 boot strapping pin, so it cannot be held during reset
  without entering the ROM download mode. The config portal is requested by
  **holding the button for 3 seconds while the device is running**, not
  during reset.

## Hardware and wiring

`HardwareConfig.h` contains the board-specific defaults. Check that each pin
is actually exposed and usable on the particular ESP32-S3 module before
wiring; read the LED-pin warning above first.

| Function | Default GPIO | Default configuration |
| --- | ---: | --- |
| ZE03-CO UART0 receive (sensor TX) | GPIO17 | `CO_RX_PIN`, 9600 8N1 |
| ZE03-CO UART0 transmit (sensor RX) | GPIO18 | `CO_TX_PIN` |
| LD2410 UART1 receive (radar TX) | GPIO15 | `PRESENCE_RX_PIN`, 256000 8N1 |
| LD2410 UART1 transmit (radar RX) | GPIO16 | `PRESENCE_TX_PIN` |
| PMS5003T UART2 receive (sensor TX) | GPIO13 | `PARTICULATE_RX_PIN`, 9600 8N1 |
| PMS5003T UART2 transmit (sensor RX) | GPIO14 | `PARTICULATE_TX_PIN` |
| MQ5 analog output | GPIO10 | `GAS_ADC_PIN`, ADC1_CH9, 12-bit, 11 dB |
| External gas detector relay (NC) | GPIO11 | `GAS_DETECTOR_PIN`, `INPUT_PULLUP`, 200 ms debounce |
| RGB LED red | GPIO21 | `LED_RED_PIN`, PWM 5 kHz, 8-bit |
| RGB LED green | GPIO47 | `LED_GREEN_PIN` |
| RGB LED blue | GPIO48 | `LED_BLUE_PIN`, `LED_COMMON_ANODE = false` |
| Active-buzzer driver | GPIO39 | `BUZZER_ACTIVE_HIGH = true` |
| Config button | GPIO0 | `CONFIG_BUTTON_ACTIVE_LOW = true`, `INPUT_PULLUP` |
| SSD1306 OLED SDA (optional) | GPIO8 | `DISPLAY_SDA_PIN`, I2C 400 kHz, address `0x3C` |
| SSD1306 OLED SCL (optional) | GPIO9 | `DISPLAY_SCL_PIN` |

The sensors, the ESP32-S3, and any driver circuits need a shared ground.

**ZE03-CO (UART0).** Supply 5 V. Its signal levels are 3 V TTL. Sensor TX goes
to GPIO17, sensor RX to GPIO18. The firmware only reads the 9-byte
active-upload frame; if the module is found in question-and-answer mode and
the channel is stale, it writes the 9-byte active-upload request once every
10 seconds (`CO_SEND_RECOVERY_COMMAND`, `CO_RECOVERY_INTERVAL_MS`) to nudge it
back. Because UART0 is taken, the debug console lives on the native USB port.

**MQ5 (GPIO10).** Supply the heater at 5 V from a source that can carry it;
the heater draws far more than a logic pin can. Feed the AO through a divider
sized for 2.5 V or less at full scale, then into GPIO10. The reference build
uses 15 kOhm from AO to GPIO10 and 10 kOhm from GPIO10 to GND, which passes
0.4 of AO (2.0 V at a 5 V swing); the default gas thresholds assume that
ratio. Fitting the resistors the other way round gives 3.0 V and clips. GPIO10 is ADC1_CH9,
and ADC1 keeps working while Wi-Fi is active, which ADC2 does not. The
firmware samples every 50 ms and averages 16 samples, so the controller sees a
new gas value roughly every 800 ms.

**External gas detector (GPIO11).** A mains-powered household gas detector's
isolated dry relay contact, read as an extra input: COM to GND, NC through a
1 kOhm series resistor to GPIO11, and 33 nF from GPIO11 to GND. The internal
pull-up is enabled; an external 10 kOhm to 3.3 V may be added. LOW means
normal (NC closed). HIGH means the detector is alarming **or the wiring is cut
or unplugged**; the two are indistinguishable by design, so an open circuit
always reads as an alarm. A level change is accepted once it has held for
200 ms (`GAS_DETECTOR_DEBOUNCE_MS`); the boot state is reported as read. The
state appears as `gas_detector.alarm` in the status document, transitions are
logged as `[gas-detector] …` and pushed over MQTT straight away. It is
monitoring only: it does not sound this device's buzzer or change its LED, and
nothing in the firmware drives the detector or its gas valve.

**LD2410 (UART1).** Sensor TX to GPIO15, sensor RX to GPIO16, 256000 baud.
LD2410, LD2410B, and LD2410C share this framing exactly, and all three leave
the factory at 256000; a plain LD2410 built to protocol revision V1.03 ships
at 57600 instead, so change `PRESENCE_BAUD` before suspecting the wiring if no
presence frames ever arrive. The LD2410S and LD2410D are different parts: the
S defaults to a minimal `6E`-to-`62` format and the D emits ASCII lines, both
at 115200, so neither ever syncs here and the symptom is silence rather than
corrupt data. The firmware only consumes the cyclic target-report stream and
never writes to the radar, so the module keeps whatever sensitivity and gate
configuration it was last given. GPIO15 and GPIO16 double as the 32.768 kHz
crystal pins, which matters only on a board that actually fits that crystal.

**PMS5003T (UART2).** Sensor TX to GPIO13, sensor RX to GPIO14, 9600 baud. The
T variant reuses the standard 32-byte frame but replaces the >5.0 um and
>10 um particle-count fields with temperature and humidity. **Confirm the part
is a PMS5003T before wiring it.** A plain PMS5003 sends the same 32-byte frame
with the same length field and a valid checksum, so the parser accepts it and
turns its >5.0 um particle count into a plausible-looking temperature. Nothing
detects that at runtime; the model is a wiring fact, not a runtime discovery.
The device's own laser and fan warm the air passing through it, and the
module's temperature and humidity calibration varies between production
batches, so `CLIMATE_TEMPERATURE_OFFSET_TENTHS_C` and
`CLIMATE_HUMIDITY_OFFSET_TENTHS_PERCENT` (both `0` by default, both in tenths)
are added to the raw values. Measure against a reference before changing them.
Only an additive offset is applied; a unit that needs a gain term as well
requires a code change in `calibratedClimate()`.

All three sensor UARTs are opened with an explicit RX/TX pin pair and a
1024-byte driver receive buffer (`UART_RX_BUFFER_BYTES`), because the hardware
FIFO is only 128 bytes and the radar alone streams at 256000 baud. Each is
drained at most 192 bytes per pass through `loop()`, so one chatty sensor
cannot starve the others. Never open a sensor UART without explicit pins:
`Serial2` defaults to GPIO19/20, which are the USB data pins.

**LED and buzzer.** GPIO21/47/48 drive the LED through `analogWrite()` at 5 kHz
with 8-bit resolution. `LED_COMMON_ANODE` is `false`, so a common-anode LED
needs that flag flipped as well as suitable series resistors. GPIO39 is
intended for an active buzzer or its driver; use a transistor driver when the
buzzer voltage or current exceeds the ESP32-S3 GPIO limits, and add flyback
suppression for an inductive load.

**SSD1306 OLED (I2C, optional).** A 128x64 SSD1306 module: VCC to 3.3 V,
GND, SDA to GPIO8, SCL to GPIO9. Most modules carry their own pull-ups; add
4.7 kOhm to 3.3 V on SDA and SCL if yours does not. The address is `0x3C`
(`DISPLAY_I2C_ADDRESS`; `0x3D` when the module's address jumper is moved).
At boot the firmware probes the address. With no answer it logs
`[display] no SSD1306 at 0x3C; display off` and runs exactly as without a
display; set `DISPLAY_ENABLED = false` to skip the probe entirely. The display
is drawn by its own low-priority task every 250 ms (`DISPLAY_REFRESH_MS`).
The safety loop only hands it a snapshot, so a slow, missing or failing
display never delays the LED or the buzzer. The display is a convenience: it
is not part of the alarm, and the alarm never depends on it.

### Display

The top row always shows the connection status: `WiFi -61dBm` or `No WiFi` on
the left, and on the right the MQTT broker (the hub): `Hub OK`, `Hub lost`
(enabled but not connected), `Hub off` (MQTT disabled) or `Updating` while an
OTA upload runs. While the setup portal is open it reads `Setup <name>-setup`,
the access point to join.

Normally the four rows below show the readings, each with the channel's grade
on the right (`ok`, `warm`, `WARN`, `DANGER`, `FAULT`; a faulted channel shows
`--` instead of a stale value):

```
WiFi -61dBm        Hub OK
CO    3 ppm        ok
Gas   640          ok
PM2.5 7 PM10 9     ok
22.4C 42%    occupied
192.168.1.40
```

The last reading row carries temperature and humidity, then the warm-up time
left (`warm 4:12`) or the radar presence (`occupied`, `empty`). The bottom row
is the device's IP address, the portal address (`Join, open 192.168.4.1`) or
`Connecting to Wi-Fi...`.

Any alert takes over the screen below the status row: a warning shows
`WARNING`, a danger `DANGER`, then the hazard (`Carbon monoxide`,
`Combustible gas`, `Smoke or dust (PM)`), its value and the alarm state:
`Alarm sounding` (the alert area blinks inverted twice a second), `Silenced
4:59` or `Alarm if it rises` for a warning. The installer self-test shows
`SELF-TEST`. The layout is decided in `DisplayModel.cpp`, which the native
tests cover; `OledDisplay.cpp` only draws it.

### LED and buzzer vocabulary

One color per hazard class, so the cause is identifiable across a room
without reading the API. Color precedence is self-test, then hazard, then
fault, then warm-up, then nominal.

| Condition | Color | LED pattern | Buzzer |
| --- | --- | --- | --- |
| All channels nominal | green | steady, dim (brightness 24/255) | silent |
| A channel is warming up | blue | 1000 ms on / 1000 ms off | silent |
| A channel is faulted or stale | cyan | 120 ms on / 880 ms off | silent |
| Particulate warning | magenta | 400 ms on / 1600 ms off | silent |
| Combustible-gas warning | orange | 400 ms on / 1600 ms off | silent |
| CO warning | red | 400 ms on / 1600 ms off | silent |
| Particulate danger | magenta | 200 ms on / 200 ms off | 500 ms on / 2000 ms off |
| Combustible-gas danger | orange | 200 ms on / 200 ms off | 300 ms on / 300 ms off |
| CO danger | red | 200 ms on / 200 ms off | 150 ms on / 150 ms off |
| Danger, silenced | hazard color | 200 ms on / 200 ms off | silent |
| Installer self-test | red, orange, magenta, white | steady, one second each | 120 ms on / 380 ms off |

Warning severity blinks slowly and never sounds the buzzer. Danger blinks
fast and sounds a hazard-specific cadence. Silencing stops the buzzer only;
the LED keeps the fast danger blink until the hazard itself clears.

A channel is graded `ok`, `warning`, or `danger` against its configured
thresholds, or `warmup` during the warm-up window, or `fault` when no valid
frame has arrived for 15 seconds (`SENSOR_TIMEOUT_MS`). Escalating to a worse
grade needs the condition held for 3 seconds (`ALARM_TRIGGER_HOLD_MS`);
de-escalating needs it held for 30 seconds (`ALARM_CLEAR_HOLD_MS`). Entering
or leaving `warmup` and `fault` is immediate, because those are already
time-debounced by the clocks that produce them. The particulate channel takes
the worse of its PM2.5 and PM10 gradings. When more than one channel is at the
same grade, CO outranks gas, and gas outranks particulate.

## Build and upload

The checked setup was built with Arduino CLI 1.5.1, ESP32 core 3.3.11,
ArduinoJson 7.4.3, PubSubClient 2.8, WiFiManager 2.0.17, and U8g2 2.36.19 (the
OLED). The repository
includes `arduino-cli.yaml`; it places board and library data in `.arduino/`.

### Arduino CLI

Use `arduino-cli` from `PATH`, or the project-local `./.tools/arduino-cli` when
present. On a fresh setup, install the declared versions:

```bash
./.tools/arduino-cli core update-index --config-file arduino-cli.yaml
./.tools/arduino-cli core install esp32:esp32@3.3.11 --config-file arduino-cli.yaml
./.tools/arduino-cli lib install ArduinoJson@7.4.3 PubSubClient@2.8 WiFiManager@2.0.17 U8g2@2.36.19 --config-file arduino-cli.yaml
./.tools/arduino-cli compile --config-file arduino-cli.yaml \
  --fqbn esp32:esp32:esp32s3:CDCOnBoot=cdc,PartitionScheme=default \
  --warnings all --output-dir build .
```

On an Apple Silicon Mac without Rosetta 2, that compile fails with `bad CPU
type in executable` before reaching the compiler: the `builtin:ctags` tool the
board package pulls in is distributed only as an x86_64 binary. Install
Rosetta 2 (`softwareupdate --install-rosetta`) to run it.

`CDCOnBoot=cdc` is required, not a preference: it sets
`ARDUINO_USB_CDC_ON_BOOT=1`, which moves `Serial` to the native USB port and
leaves UART0 to the CO sensor. Building without it fails on the `#error` guard
in `HardwareConfig.h`. The `default` partition selection is required because
OTA needs two suitable application slots; on an 8 MB module use
`PartitionScheme=default_8MB` instead, which is also OTA-capable. Upload with
the serial port and baud rate appropriate for the board, for example (replace
the port):

```bash
./.tools/arduino-cli upload --config-file arduino-cli.yaml \
  --fqbn esp32:esp32:esp32s3:CDCOnBoot=cdc,PartitionScheme=default \
  --port /dev/ttyACM0 --input-dir build .
```

### Arduino IDE

1. Add `https://espressif.github.io/arduino-esp32/package_esp32_index.json` to
   **Preferences → Additional Boards Manager URLs**.
2. Install **esp32 by Espressif Systems** version 3.3.11 from Boards Manager.
3. Install these Library Manager versions: ArduinoJson 7.4.3, PubSubClient 2.8,
   WiFiManager 2.0.17, and U8g2 2.36.19.
4. Open this directory as the `air_sensor` sketch, select an ESP32-S3 board
   matching the hardware, set **USB CDC On Boot** to **Enabled**, select the
   **default** OTA-capable partition scheme, then compile/upload. Review
   `HardwareConfig.h` before the first upload, and read the LED-pin note above
   before switching to the alternative LED pins.

## Provisioning, configuration, and recovery

On first run, or when no usable configuration exists, the device opens a
WiFiManager captive portal named `<device-name>-setup`; with default settings
that is `canary-setup`. Join that access point and complete the portal. The
API token is mandatory and must be 12–64 characters. MQTT is optional; set
MQTT enabled to `1` and provide a broker host to use it, or leave it disabled.
The portal is non-blocking and times out after 300 seconds.

| Portal field | Label | Default |
| --- | --- | --- |
| `device_name` | Device name | `canary` |
| `mqtt_enabled` | MQTT enabled (0 or 1) | `0` |
| `mqtt_host` | MQTT host | empty |
| `mqtt_port` | MQTT port | `1883` |
| `mqtt_user` | MQTT user | empty |
| `mqtt_password` | MQTT password (leave blank to keep) | empty |
| `mqtt_topic` | MQTT base topic | `canary` |
| `api_token` | API token (12-64 chars; blank keeps existing) | none |
| `co_warn_ppm` | CO warning ppm | `50` |
| `co_danger_ppm` | CO danger ppm | `100` |
| `gas_warn_adc` | MQ5 warning ADC | `1200` |
| `gas_danger_adc` | MQ5 danger ADC | `1760` |
| `warmup_seconds` | Sensor warm-up seconds | `300` |
| `pm25_warn` | PM2.5 warning ug/m3 | `35` |
| `pm25_danger` | PM2.5 danger ug/m3 | `150` |
| `pm10_warn` | PM10 warning ug/m3 | `100` |
| `pm10_danger` | PM10 danger ug/m3 | `250` |
| `silence_seconds` | Alarm silence seconds | `300` |

Every warning value must be greater than zero and strictly below its danger
value, and each danger value must stay inside the sensor's representable
range: 2000 ppm for CO, 4095 counts for the MQ5, and 1000 ug/m3 for both
particulate sizes. Warm-up accepts 10–3600 seconds and the alarm silence
window accepts 30–3600 seconds. The MQTT port must not be zero, and a broker
host is required when MQTT is enabled.

Stored passwords and tokens are not rendered back into the portal: leave a
secret field blank to retain its existing value. Submitted secrets are cleared
from the WiFiManager parameter buffers before the portal can render another
page. Invalid submissions restart the portal rather than saving an incomplete
configuration; a device that already had a valid configuration keeps its
stored Wi-Fi credentials across that restart, while a device that never had
one has them cleared. A successful save is written to NVS and the device then
restarts to apply it.

To reopen provisioning later, press and hold the config button for 3 seconds
at any time while the device is running. The device restarts straight into the
setup portal. GPIO0 is a boot strapping pin, so do not hold it while powering
on or pressing reset: that enters the ROM download mode instead of this
firmware. The hold is ignored while an OTA upload or a configuration save is in
progress. With the shipped defaults the
button is active-low and uses the internal pull-up, so hold it to GND. Do not
assume another board's BOOT button is wired identically without checking it.

## Calibrating the MQ5 and choosing thresholds

The MQ5 value in the API is a raw 12-bit ADC count, so its thresholds have to
be derived from the installed sensor in the installed location. They are not
transferable between builds.

Read the live values from the unauthenticated status endpoint:

```bash
curl -sS http://$DEVICE_IP/api/status | jq '{gas, co, particulate, climate}'
```

1. Run the heater continuously for 24–48 hours before recording anything. A
   new MQ5 element drifts heavily during burn-in and its readings before then
   mean nothing.
2. With the divider fitted, confirm the voltage at GPIO10 stays at or below
   2.5 V with the sensor at its highest expected output. Above roughly 2.9 V
   the ADC saturates at the 11 dB attenuation this firmware configures, so a
   badly sized divider silently clips the top of the range.
3. Record `gas.adc` across a full day/night cycle in the installed location,
   with the normal ventilation, cooking, and occupancy patterns of that room.
   Note the ceiling of that quiet-air band.
4. Set `gas_warn_adc` above the observed ceiling with margin for drift, and
   `gas_danger_adc` above that with separation for noise. For example, a
   quiet-air band topping out at 720 counts might be configured as warn 1200
   and danger 1760, which are the shipped defaults. Those are an example, not
   universal values, and they assume the 15k/10k divider: a different divider
   ratio scales every reading, so scale the thresholds with it.
5. Optionally bump-test with a known source at a safe distance and confirm the
   reading rises well past the danger threshold before choosing final values.

Recheck periodically. MQ5 sensitivity changes with element age, ambient
temperature, and humidity, and the sensor is not gas-selective, so a rise
identifies "something combustible or otherwise reducing" and not which gas.

The CO and particulate thresholds are in real units and can start from the
defaults, but they are still policy choices for the installation rather than
regulatory limits. `co_warn_ppm` 50 and `co_danger_ppm` 100 sit in the region
where sustained exposure becomes a concern for healthy adults; lower both for
a bedroom or a space used by children, elderly, or pregnant occupants. The
PM2.5 and PM10 defaults follow common outdoor-air-quality band edges and will
trip on ordinary cooking in a small kitchen, so raise them or move the sensor
if that is a nuisance rather than a signal.

`warmup_seconds` must cover the slowest sensor in the build. The ZE03-CO needs
at least 5 minutes, which is what the 300-second default provides; no channel
can raise a hazard and no peak is recorded until the window elapses.

**Warm-up after a short power cut.** Once Wi-Fi is up, the device sets its
clock over SNTP, asking the MQTT host (the hub) first and `pool.ntp.org`
second. While the clock is set, it saves the current time to NVS every 10 s.
After the next boot it compares the two once the clock is set again: if the
power was off for under 30 s, the warm-up window shrinks to 60 s from boot
instead of the configured length. Without a synced clock, or with no stamp
from a run that had one, the full window applies. Warm-up is shortened rather
than skipped because the MQ5 heater and the ZE03 cell both read high for a
while after power returns, and the PMS5003 fan needs about 30 s to settle.
The stamp is up to 10 s old when the power drops, which overstates the gap,
so only cuts of up to about 20 s are certain to qualify. For the hub to
answer, run an NTP server on the Pi host (for example `chrony` with an
`allow` line for the sensor LAN); otherwise the device needs internet
access to reach the fallback server.

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
hyphen (`canary` by default, `canary-air` if nothing usable remains). Use
`http://<name>.local` wherever this guide says `$DEVICE_IP`, for example
`export DEVICE_IP=canary.local`. Every Canary sensor also advertises a
`_canary._tcp` service on port 80 with TXT records `type=air`, `fw` and
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
# ~/.config/canary/http-curl.conf (mode 0600)
header = "Authorization: Bearer <API_TOKEN>"

# ~/.config/canary/mosquitto.conf (mode 0600)
-h <BROKER>
-u <USER>
-P <PASS>
```

The `-P` setting is safe from command-line process inspection only because it
is inside the protected Mosquitto option file, not an argument to
`mosquitto_pub` or `mosquitto_sub`. Set the non-secret option-file paths once:

```bash
export HTTP_CURL_CONFIG="$HOME/.config/canary/http-curl.conf"
export MQTT_OPTIONS="$HOME/.config/canary/mosquitto.conf"
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
| `warmup_remaining_seconds` | Seconds left in the warm-up window, rounded up; 0 once elapsed |
| `co.ppm`, `co.peak_ppm` | Latest CO reading and the highest since boot; peaks are not recorded during warm-up and do not survive restart |
| `co.state` | `warmup`, `ok`, `warning`, `danger`, or `fault` |
| `co.warn_ppm`, `co.danger_ppm` | Configured CO thresholds |
| `co.valid`, `co.age_ms` | Whether a frame arrived inside the 15-second sensor timeout, and the age of the last accepted frame (0 if none ever arrived) |
| `gas.adc`, `gas.peak_adc` | Latest averaged 12-bit MQ5 count and its peak since boot |
| `gas.state` | Same vocabulary as `co.state` |
| `gas.warn_adc`, `gas.danger_adc` | Configured MQ5 thresholds, in raw ADC counts |
| `particulate.pm1_0`, `particulate.pm2_5`, `particulate.pm10` | Atmospheric-environment concentrations in ug/m3 |
| `particulate.peak_pm2_5`, `particulate.peak_pm10` | Highest PM2.5 and PM10 since boot |
| `particulate.state` | The worse of the PM2.5 and PM10 gradings |
| `particulate.warn_pm2_5`, `particulate.danger_pm2_5` | Configured PM2.5 thresholds |
| `particulate.warn_pm10`, `particulate.danger_pm10` | Configured PM10 thresholds |
| `particulate.valid`, `particulate.age_ms` | Frame freshness against the 15-second sensor timeout |
| `climate.temperature_c`, `climate.humidity_percent` | PMS5003T temperature in C and relative humidity in %, after the compiled offsets |
| `climate.valid`, `climate.age_ms` | Freshness against the 15-second sensor timeout |
| `presence.detected`, `presence.moving`, `presence.stationary` | LD2410 target state; all three are false during the radar's background-calibration states, which are valid frames rather than a detection |
| `presence.moving_distance_cm`, `presence.moving_energy` | Moving-target distance and energy |
| `presence.stationary_distance_cm`, `presence.stationary_energy` | Stationary-target distance and energy |
| `presence.detection_distance_cm` | The radar's own reported detection distance |
| `presence.valid`, `presence.age_ms` | Freshness against the 3-second presence timeout |
| `alarm.state` | `inactive`, `warning`, `sounding`, or `silenced` |
| `alarm.hazard` | `none`, `co`, `gas`, or `particulate` |
| `alarm.sounding` | True only while the state is `sounding` |
| `alarm.silence_remaining_seconds` | Seconds left in the silence window, rounded up; 0 when not silenced |
| `alarm.self_test` | Whether an installer self-test is running |
| `alarm.led_color` | `off`, `green`, `blue`, `cyan`, `magenta`, `orange`, `red`, or `white` |
| `alarm.led_on` | Whether the LED is in the on phase of its blink at the instant the document was built |
| `wifi.connected`, `wifi.rssi` | Wi-Fi state and RSSI (0 when disconnected) |
| `wifi.ip` | IPv4 address while Wi-Fi is connected (absent otherwise; firmware 1.1.0+). The hub suggests it as the firmware push address |
| `mqtt.enabled`, `mqtt.connected` | MQTT configuration and current connection state |
| `ota.in_progress` | Whether an authenticated OTA update is active |

```bash
curl -sS http://$DEVICE_IP/api/status | jq .
```

### `POST /api/buzzer`

Payloads are `{"command":"silence"}` or `{"command":"test"}`. The command
value is case-insensitive. A successful request returns the same status
document as `GET /api/status`.

```bash
# Expected 401: authentication is required even to silence the buzzer.
curl -i -X POST http://$DEVICE_IP/api/buzzer \
  -H 'Content-Type: application/json' -d '{"command":"silence"}'

curl -i -X POST http://$DEVICE_IP/api/buzzer \
  --config "$HTTP_CURL_CONFIG" \
  -H 'Content-Type: application/json' -d '{"command":"silence"}'

curl -i -X POST http://$DEVICE_IP/api/buzzer \
  --config "$HTTP_CURL_CONFIG" \
  -H 'Content-Type: application/json' -d '{"command":"test"}'
```

`silence` is accepted only while the alarm is actually sounding. It grants a
silence for the configured window, covering exactly the hazard that was
sounding: a different hazard becoming the top danger, the danger clearing, or
the window expiring all retire it. It stops the buzzer only; the LED keeps its
fast danger blink.

`test` runs a 4-second installer self-test that steps the LED through red,
orange, magenta, and white while pulsing the buzzer. It is rejected while an
alarm is sounding or silenced, while another self-test is running, and during
an OTA. A real danger appearing mid-test cancels the test immediately.

Errors use `{"error":"…","message":"…"}` (the emergency serialization
fallback is `{"error":"internal_error"}`). The implemented error keys are:

| HTTP status | `error` key | Situation |
| ---: | --- | --- |
| 400 | `invalid_request` | Malformed request line or header, missing/invalid command, required `Content-Length` absent, or body data beyond the declared length |
| 401 | `unauthorized` | Missing or invalid bearer token |
| 404 | `not_found` | Unknown route |
| 409 | `alarm_inactive` | Silence requested with no sounding alarm |
| 409 | `self_test_busy` | Self-test requested while an alarm is active or another self-test is running |
| 409 | `ota_active` | Self-test requested during OTA, or another OTA is active |
| 413 | `payload_too_large` | Buzzer request body exceeds 128 bytes |
| 431 | `headers_too_large` | Request headers exceed the 512-byte parser limit |
| 500 | `status_unavailable` | Status JSON could not be produced |
| 500 | `ota_failed` | Firmware upload failed; message gives the bounded update error |
| 500 | `internal_error` | Emergency error-serialization fallback |

## MQTT (optional)

Configure MQTT in the portal before use. The client uses the configured broker
credentials, not the HTTP bearer token. It runs on its own worker task so the
safety loop never touches a socket. It connects with a device-derived client
ID, sends a retained last will of `offline`, publishes retained `online` after
reconnection, and publishes retained status on state changes and at least
every 15 seconds. It uses plaintext `WiFiClient` MQTT with no TLS: broker
credentials, commands, and status need the same trusted-LAN or isolated-IoT-VLAN
protection as HTTP and OTA.

With configured base topic `<base>` (the default is `canary`), these are all
MQTT topics:

| Topic | Direction and retention | Payload |
| --- | --- | --- |
| `<base>/availability` | Device publish, retained | `online`; last-will `offline` |
| `<base>/status` | Device publish, retained | The same status JSON fields listed above |
| `<base>/buzzer/set` | Device subscription, QoS 1 | Case-insensitive `SILENCE` or `TEST`, surrounding whitespace ignored |
| `<base>/command/result` | Device publish, not retained | Command-result JSON below |

Publish commands as **non-retained** messages. Retaining an MQTT command can
cause it to be processed after a later reconnect; retained status and
availability are intentional, retained commands are not.

Command results have either
`{"command":"SILENCE|TEST","accepted":true,"state":"silenced|self_test"}` or
`{"command":"…","accepted":false,"error":"…"}`. Error values are
`invalid_command`, `busy`, `alarm_inactive`, `self_test_busy`, `ota_active`,
`command_rejected`, or `status_serialization_failed` (for the internal
`STATUS` result). An unrecognized or oversized command payload is answered as
command `UNKNOWN` with `invalid_command`. MQTT payloads never contain the HTTP
API token.

```bash
mosquitto_sub -o "$MQTT_OPTIONS" -v -t 'canary/#'
mosquitto_pub -o "$MQTT_OPTIONS" \
  -t 'canary/buzzer/set' -m SILENCE
mosquitto_pub -o "$MQTT_OPTIONS" \
  -t 'canary/buzzer/set' -m TEST
```

Replace `canary` in those topic arguments when a different base topic is
configured. The commands above omit `-r` deliberately.

### ESP-NOW backup link

When a node has MQTT enabled but loses its MQTT session (usually because its
Wi-Fi dropped), it keeps sending its status document over ESP-NOW instead, on
every change and every 15 seconds. Every node listens. A node with a live
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
and API token once, then send `build/air_sensor.ino.bin` to one or many sensors
(the hub uploads to this same `/api/ota`, one device at a time, and confirms
the version the device reports after its reboot;
[`RPISoftware/docs/HARDWARE.md`](../RPISoftware/docs/HARDWARE.md) §4, Firmware).
Devices on 1.0.0 do not report `wifi.ip`: type the address. Alternatively:

```bash
# Expected 401 and no write: missing Authorization header.
curl -i -X POST -H 'Expect:' -F 'firmware=@build/air_sensor.ino.bin' \
  http://$DEVICE_IP/api/ota

# Expected OTA error: deliberately not a firmware image.
curl -i -X POST --config "$HTTP_CURL_CONFIG" -H 'Expect:' \
  -F 'firmware=@HardwareConfig.h' \
  http://$DEVICE_IP/api/ota

# Expected success response: {"ok":true,"rebooting":true}.
curl -i -X POST --config "$HTTP_CURL_CONFIG" -H 'Expect:' \
  -F 'firmware=@build/air_sensor.ino.bin' http://$DEVICE_IP/api/ota
```

`-H 'Expect:'` stops curl from pausing about a second before a large upload to
wait for a `100 Continue` reply the firmware does not send; without it the
device's 1-second idle limit fails the upload with `Firmware upload timed out`.

The OTA request authenticates before any flash write begins, and rejects a
second concurrent upload with `ota_active`. **An OTA does not mute a live
alarm**: the LED and buzzer keep running through the upload, because an update
must never silence a real CO or gas warning. An OTA does cancel a running
self-test and blocks starting a new one. The device reboots after a successful
response. A failed upload leaves the prior bootable firmware in place and
releases the OTA interlock. Recheck `/api/status` after the reboot.

## Deferred capabilities

- HTTPS, MQTT TLS, device certificate provisioning, cloud integration, and
  Arduino IDE `ArduinoOTA` uploads.
- Home Assistant MQTT discovery.
- Multiple users or role-based authorization.
- Any ppm or %LEL conversion for the MQ5, and any gas discrimination: the
  combustible-gas channel stays a raw ADC count graded against raw thresholds.
- Presence-driven behavior. The LD2410 reading is reported only; it does not
  gate, escalate, suppress, or delay any alarm.
- LD2410 configuration over its command frame family (sensitivity, gate setup,
  engineering mode). Only the cyclic report stream is read.
- ZE03 question-and-answer polling as a primary operating mode. Only the
  one-shot active-upload recovery write is implemented.
- Gain correction for the PMS5003T climate reading. Only an additive offset
  is applied, so a unit needing a multiplier as well needs a code change.
- Runtime detection of the wrong sensor variant. A plain PMS5003 or a
  mismatched LD2410 model is a wiring error the firmware cannot report.
- An audible indication of a faulted or missing sensor, and any end-of-life or
  sensor-aging tracking.
- Persisted history, event logs, or peak retention across reboot.

## Hardware verification checklist (perform on the installed system)

This checklist is intentionally not marked as completed by the repository.
Record the observed results and installation details below only after testing
the actual board, sensors, LED, and buzzer.

- [ ] Record the ESP32-S3 module part number and PSRAM type. Confirm all three
  LED channels (GPIO21, GPIO47, GPIO48) actually light. If the alternative
  GPIO37/36/38 set is in use, confirm the module has no Octal PSRAM: on an `R8`
  or `R16V` module GPIO36 and GPIO37 drive nothing.
- [ ] From power-on until `setup()` completes, confirm the buzzer stays
  silent; add an external pull-down on GPIO39 if it chirps.
- [ ] If an SSD1306 is fitted: confirm the boot screen, then readings, Wi-Fi
  and `Hub OK`; run the self-test and a CO/gas test exposure and confirm the
  alert screen appears with the LED and buzzer. Unplug the display's SDA line
  while running and confirm the LED and buzzer timing do not change.
- [ ] With the MQ5 heater at temperature, measure the divider output at the
  sensor's highest expected reading and confirm it stays at or below 2.5 V.
- [ ] After 24–48 hours of MQ5 burn-in, record `gas.adc` across a full
  day/night cycle and set the warn and danger thresholds above the observed
  quiet-air ceiling.
- [ ] Confirm `co.valid`, `particulate.valid`, and `presence.valid` are all
  true in `/api/status`, and that `climate.temperature_c` and
  `climate.humidity_percent` are plausible against a reference instrument.
- [ ] Confirm `warmup_remaining_seconds` counts down and every channel leaves
  `warmup` at the end of the window.
- [ ] Disconnect each UART sensor in turn. Confirm its channel reaches `fault`
  within 15 seconds (3 seconds for presence), the LED turns cyan, and the
  buzzer stays silent.
- [ ] Bump-test each hazard channel. Confirm the warning grade after the
  3-second trigger hold, then the danger grade, then the correct LED color
  and buzzer cadence for that hazard.
- [ ] With two channels in danger simultaneously, confirm CO wins the LED
  color and buzzer cadence over gas, and gas over particulate.
- [ ] Confirm clean air clears the alarm by itself after the 30-second clear
  hold, with no acknowledgement.
- [ ] Confirm an authenticated `silence` stops the buzzer only, that the LED
  keeps its fast danger blink, and that the silence retires when the window
  expires or the hazard changes.
- [ ] Confirm an authenticated `test` runs the 4-second self-test, that it is
  rejected while an alarm is active, and that a real danger cancels one in
  progress.
- [ ] Disconnect Wi-Fi and the broker, then trigger a hazard. Confirm the LED
  and buzzer still respond.
- [ ] Confirm missing or invalid bearer tokens cannot silence the buzzer, start
  a self-test, or upload firmware.
- [ ] Confirm an OTA does not mute a live alarm, that a valid image reboots
  into the intended firmware version, and that a failed upload leaves the
  prior firmware bootable.
- [ ] Confirm holding the config button for 3 seconds while running restarts
  into the `<device-name>-setup` portal, and that holding it through reset instead enters
  the ROM download mode.
- [ ] Confirm an invalid portal submission reopens the portal without saving,
  and that a valid save persists across restart.
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
Room / mounting height / distance to likely source:

Board model and full module part number (PSRAM type):
LED pin set in use (default 37/36/38 or alternative 21/47/48):
Firmware version (from /api/status):
Buzzer/driver and active level verified (HIGH/LOW):
Power-on buzzer chirp observed (yes/no; pull-down fitted):

ZE03-CO module and firmware revision:
MQ5 module and burn-in hours completed:
MQ5 divider ratio and measured full-scale voltage at GPIO10:
PMS5003T module (confirm T variant):
LD2410 module variant:
Climate offsets applied (tenths C / tenths %):

Observed quiet-air MQ5 ADC range (day / night):
Configured MQ5 warning / danger ADC:
Configured CO warning / danger ppm:
Configured PM2.5 warning / danger ug/m3:
Configured PM10 warning / danger ug/m3:
Configured warm-up (s):
Configured alarm silence window (s):

Certified CO / smoke alarms present at this site:
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
the build section. Native tests exercise the platform-neutral alarm state
machine, the three sensor frame parsers, configuration validation and
fallback, authentication, MQTT command/connection behavior, and the ESP-NOW
backup link's frame format, signing, replay protection and MQTT
fallback/relay; they do not substitute for the installed hardware checklist.

`scripts/` also holds static invariant checks that read the source rather than
running it:

```bash
scripts/check-safety-regressions.sh
scripts/verify-http-transport-safety.sh
scripts/verify-ota-transport-safety.sh
scripts/verify-ota-parser-regressions.sh
```

`check-safety-regressions.sh` asserts that the USB CDC build guard still fails
the build, that every sensor UART is opened with explicit pins, that the
Octal-PSRAM LED warning is still in both `HardwareConfig.h` and this README,
that no latch has crept back into the level-based alarm, that warm-up still
gates every hazard channel, and that neither silencing nor OTA can reach the
visual alarm. The transport checks assert that HTTP and OTA stay on the
bounded, authenticated incremental transport instead of `WebServer`, and that
the OTA parser cannot recurse, always answers a timeout before releasing the
interlock, and only schedules a reboot after a fully delivered success
response. `verify-http-transport-safety.sh` reads the pinned WebServer source
under `.arduino/`, so install the core with the Arduino CLI commands above
first. The other three read only this directory.

The sketch compiles warning-clean against ESP32 core 3.3.11 for
`esp32:esp32:esp32s3` and uses about 81% of the 1.25 MB OTA application slot
and 14% of dynamic memory. Nothing in this directory has been run on
hardware.

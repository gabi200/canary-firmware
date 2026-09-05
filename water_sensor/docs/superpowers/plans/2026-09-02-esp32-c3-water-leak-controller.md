# ESP32-C3 Water Leak Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a testable Arduino sketch for an ESP32-C3 that detects water, safely latches a relay-controlled valve closed, alarms through an active buzzer, exposes HTTP and MQTT control/status, provisions through a captive portal, and accepts authenticated web OTA updates.

**Architecture:** Keep all time-sensitive safety behavior in a platform-neutral `LeakController`, with ESP32 adapters for GPIO, Preferences, captive-portal networking, HTTP/OTA, and MQTT. The sketch owns the non-blocking loop and passes every HTTP/MQTT command through the same controller methods, so network availability cannot bypass or stall safety behavior.

**Tech Stack:** C++17, Arduino ESP32 core 3.3.11, Arduino CLI 1.5.1, WiFiManager 2.0.17, PubSubClient 2.8, ArduinoJson 7.4.3, ESP32 `WebServer`/`Preferences`/`Update`, and a native `g++` test executable.

**Spec:** `docs/superpowers/specs/2026-09-02-esp32-c3-water-leak-controller-design.md`

## Global Constraints

- Target an ESP32-C3 and compile with an OTA-capable `default` partition scheme.
- Power the analog water sensor from 3.3 V; never apply a 5 V sensor output to an ESP32-C3 ADC.
- Default the relay and active buzzer to active-HIGH, but make both polarities compile-time configurable.
- Close the valve at boot, on every stable wet event, and before OTA writing begins.
- Never reopen automatically after a leak latch; require an authenticated open command while the stable sensor state is dry.
- Keep sensor sampling, valve output, buzzer timing, HTTP servicing, WiFiManager processing, and MQTT reconnect work non-blocking.
- Default buzzer alarm duration is 180 seconds; silence/timeout must never clear the latch or open the valve.
- Store secrets in Preferences and never emit them through Serial, status JSON, or MQTT.
- HTTP is LAN-only and unencrypted; document the trusted-LAN/IoT-VLAN requirement.
- The current workspace is not a Git repository. Do not initialize one implicitly. Run each commit step only if the user has initialized Git before execution; otherwise note it as skipped.

## Planned File Structure

- `water_sensor.ino`: Arduino entry points, sensor scheduler, safe GPIO application, and service coordination.
- `OutputLogic.h`: platform-neutral active-HIGH/active-LOW mapping.
- `HardwareConfig.h`: board pins, output polarities, ADC/sample timing, beep cadence, and firmware version.
- `LeakController.h`, `LeakController.cpp`: platform-neutral hysteresis, debounce, latch, valve rules, OTA interlock, buzzer alarm, and persistence-dirty state.
- `DeviceConfig.h`, `DeviceConfig.cpp`: fixed-size configuration structure, defaults, and validation.
- `Auth.h`, `Auth.cpp`: bounded bearer-header parsing and timing-insensitive token comparison.
- `ConfigStore.h`, `ConfigStore.cpp`: explicit Preferences keys for configuration and persistent latch/valve state.
- `NetworkConfig.h`, `NetworkConfig.cpp`: non-blocking WiFiManager portal and custom parameter lifecycle.
- `StatusJson.h`, `StatusJson.cpp`: one bounded status document shared by HTTP and MQTT.
- `HttpApi.h`, `HttpApi.cpp`: status, authenticated valve/buzzer endpoints, update page, and streaming OTA endpoint.
- `MqttService.h`, `MqttService.cpp`: reconnect backoff, last will, command subscriptions, result messages, and retained status.
- `tests/native/test_main.cpp`: native behavioral tests and small assertion harness.
- `scripts/run-native-tests.sh`: warning-clean native build and test command.
- `arduino-cli.yaml`: repository-local Arduino CLI directories and Espressif board index.
- `.gitignore`: local Arduino packages, build output, and native test binary.
- `README.md`: wiring, setup, calibration, API/MQTT examples, OTA workflow, and hardware verification checklist.

---

### Task 1: Safety State Machine and Buzzer Alarm

**Files:**
- Create: `LeakController.h`
- Create: `LeakController.cpp`
- Create: `tests/native/test_main.cpp`
- Create: `scripts/run-native-tests.sh`

**Interfaces:**
- Consumes: ADC averages and monotonic `uint32_t` millisecond timestamps from the future sketch.
- Produces: `LeakController(LeakConfig)`, `restore(PersistentState, uint32_t)`, `updateSensor(uint16_t, uint32_t)`, `requestValve(ValveState, uint32_t)`, `silenceAlarm()`, `setOtaActive(bool)`, `tick(uint32_t)`, `buzzerOutput(uint32_t)`, `alarmRemainingMs(uint32_t)`, `persistentState()`, and `takePersistentDirty()`.

- [ ] **Step 1: Write the failing native state-machine tests**

Create `tests/native/test_main.cpp` with a tiny runner and concrete tests for startup, hysteresis/debounce, wet latching, dry-not-clearing, open rejection, dry open, OTA rejection, alarm cadence, silence, timeout, repeat wet, restored latch, persistence dirtiness, and unsigned-millisecond wraparound. Start with this harness and representative assertions, then add one named function per listed behavior:

```cpp
#include "LeakController.h"
#include <cstdlib>
#include <iostream>

static int failures = 0;
#define CHECK(expr) do { if (!(expr)) { std::cerr << __func__ << ":" << __LINE__ << " CHECK(" #expr ") failed\n"; ++failures; } } while (0)

static LeakConfig config() {
  return LeakConfig{1200, 600, 1000, 180000, 500, 500};
}

static void establishDry(LeakController& c, uint32_t start = 0) {
  c.updateSensor(200, start);
  c.updateSensor(200, start + 1000);
}

static void testWetLatchesAndCloses() {
  LeakController c(config());
  c.restore(PersistentState{false, ValveState::Open}, 0);
  establishDry(c);
  CHECK(c.requestValve(ValveState::Open, 1001) == CommandResult::Accepted);
  c.updateSensor(1600, 2000);
  c.updateSensor(1600, 3000);
  CHECK(c.sensorState() == SensorState::Wet);
  CHECK(c.leakLatched());
  CHECK(c.valveState() == ValveState::Closed);
  CHECK(c.alarmState(3000) == AlarmState::Sounding);
}

static void testDryDoesNotClearLatchAndWetOpenIsRejected() {
  LeakController c(config());
  c.updateSensor(1600, 0);
  c.updateSensor(1600, 1000);
  c.updateSensor(200, 2000);
  c.updateSensor(200, 3000);
  CHECK(c.sensorState() == SensorState::Dry);
  CHECK(c.leakLatched());
  c.updateSensor(1600, 4000);
  c.updateSensor(1600, 5000);
  CHECK(c.requestValve(ValveState::Open, 5001) == CommandResult::RejectedWet);
}

static void testAlarmSilenceTimeoutAndRepeatWet() {
  LeakController c(config());
  c.updateSensor(1600, 0);
  c.updateSensor(1600, 1000);
  CHECK(c.buzzerOutput(1000));
  CHECK(!c.buzzerOutput(1500));
  CHECK(c.silenceAlarm());
  CHECK(c.alarmState(1501) == AlarmState::Silenced);
  c.updateSensor(200, 2000);
  c.updateSensor(200, 3000);
  c.updateSensor(1600, 4000);
  c.updateSensor(1600, 5000);
  CHECK(c.alarmState(5000) == AlarmState::Sounding);
  c.tick(185000);
  CHECK(c.alarmState(185000) == AlarmState::TimedOut);
  CHECK(!c.buzzerOutput(185000));
}

static void testStartupRestoresOpenOnlyAfterDry() {
  LeakController c(config());
  c.restore(PersistentState{false, ValveState::Open}, 0);
  CHECK(c.valveState() == ValveState::Closed);
  establishDry(c);
  CHECK(c.valveState() == ValveState::Open);
}

static void testHysteresisAndDebounceRejectNoise() {
  LeakController c(config());
  c.updateSensor(1600, 0);
  c.updateSensor(200, 500);
  c.updateSensor(1600, 1000);
  CHECK(c.sensorState() == SensorState::Uninitialized);
  c.updateSensor(1600, 2000);
  CHECK(c.sensorState() == SensorState::Wet);
  c.updateSensor(900, 3000);
  CHECK(c.sensorState() == SensorState::Wet);
}

static void testDryOpenClearsLatch() {
  LeakController c(config());
  c.updateSensor(1600, 0);
  c.updateSensor(1600, 1000);
  c.updateSensor(200, 2000);
  c.updateSensor(200, 3000);
  CHECK(c.requestValve(ValveState::Open, 3001) == CommandResult::Accepted);
  CHECK(!c.leakLatched());
  CHECK(c.valveState() == ValveState::Open);
}

static void testOtaRejectsOpen() {
  LeakController c(config());
  establishDry(c);
  c.setOtaActive(true);
  CHECK(c.requestValve(ValveState::Open, 1001) == CommandResult::RejectedOta);
  CHECK(c.valveState() == ValveState::Closed);
}

static void testRestoredLatchStartsFreshAlarm() {
  LeakController c(config());
  c.restore(PersistentState{true, ValveState::Closed}, 7000);
  CHECK(c.leakLatched());
  CHECK(c.alarmState(7000) == AlarmState::Sounding);
  CHECK(c.alarmRemainingMs(7000) == 180000);
}

static void testPersistenceDirtyOnlyOnPersistentChange() {
  LeakController c(config());
  CHECK(!c.takePersistentDirty());
  c.requestValve(ValveState::Closed, 0);
  CHECK(!c.takePersistentDirty());
  establishDry(c);
  c.requestValve(ValveState::Open, 1001);
  CHECK(c.takePersistentDirty());
  CHECK(!c.takePersistentDirty());
}

static void testMillisWraparound() {
  LeakController c(config());
  const uint32_t start = UINT32_MAX - 499;
  c.updateSensor(1600, start);
  c.updateSensor(1600, 500);
  CHECK(c.sensorState() == SensorState::Wet);
}

int main() {
  testWetLatchesAndCloses();
  testDryDoesNotClearLatchAndWetOpenIsRejected();
  testAlarmSilenceTimeoutAndRepeatWet();
  testStartupRestoresOpenOnlyAfterDry();
  testHysteresisAndDebounceRejectNoise();
  testDryOpenClearsLatch();
  testOtaRejectsOpen();
  testRestoredLatchStartsFreshAlarm();
  testPersistenceDirtyOnlyOnPersistentChange();
  testMillisWraparound();
  if (failures) return EXIT_FAILURE;
  std::cout << "All native tests passed\n";
  return EXIT_SUCCESS;
}
```

- [ ] **Step 2: Add the native test command and verify the tests fail**

Create `scripts/run-native-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary_path="${TMPDIR:-/tmp}/water-sensor-native-tests"
g++ -std=c++17 -Wall -Wextra -Werror -pedantic -I"$repo_dir" \
  "$repo_dir/LeakController.cpp" \
  "$repo_dir/tests/native/test_main.cpp" \
  -o "$binary_path"
"$binary_path"
```

Run: `chmod +x scripts/run-native-tests.sh && scripts/run-native-tests.sh`

Expected: compilation fails because `LeakController.h` and its types do not exist.

- [ ] **Step 3: Define the complete platform-neutral interface**

Create `LeakController.h` with these exact public types and signatures:

```cpp
#pragma once
#include <stdint.h>

enum class SensorState : uint8_t { Uninitialized, Dry, Wet };
enum class ValveState : uint8_t { Open, Closed };
enum class AlarmState : uint8_t { Inactive, Sounding, Silenced, TimedOut };
enum class CommandResult : uint8_t { Accepted, RejectedWet, RejectedUninitialized, RejectedOta };

struct LeakConfig {
  uint16_t wetThreshold;
  uint16_t dryThreshold;
  uint32_t debounceMs;
  uint32_t alarmDurationMs;
  uint32_t beepOnMs;
  uint32_t beepOffMs;
};

struct PersistentState {
  bool leakLatched;
  ValveState requestedValve;
};

class LeakController {
 public:
  explicit LeakController(const LeakConfig& config);
  void restore(const PersistentState& state, uint32_t nowMs);
  bool updateSensor(uint16_t adcValue, uint32_t nowMs);
  CommandResult requestValve(ValveState requested, uint32_t nowMs);
  bool silenceAlarm();
  void setOtaActive(bool active);
  void tick(uint32_t nowMs);
  SensorState sensorState() const;
  ValveState valveState() const;
  bool leakLatched() const;
  bool otaActive() const;
  AlarmState alarmState(uint32_t nowMs) const;
  bool buzzerOutput(uint32_t nowMs) const;
  uint32_t alarmRemainingMs(uint32_t nowMs) const;
  PersistentState persistentState() const;
  bool takePersistentDirty();

 private:
  void enterWet(uint32_t nowMs);
  void startAlarm(uint32_t nowMs);
  static bool elapsed(uint32_t nowMs, uint32_t sinceMs, uint32_t intervalMs);
  LeakConfig config_;
  SensorState sensorState_;
  SensorState candidateState_;
  uint32_t candidateSinceMs_;
  bool candidateValid_;
  bool leakLatched_;
  ValveState requestedValve_;
  ValveState valveState_;
  bool otaActive_;
  uint32_t alarmStartedMs_;
  bool alarmActive_;
  bool alarmSilenced_;
  bool alarmTimedOut_;
  bool persistenceDirty_;
};
```

- [ ] **Step 4: Implement only the state transitions needed by the tests**

Create `LeakController.cpp`. Use unsigned subtraction for every interval, classify values between thresholds as the current candidate/stable state, require the candidate to remain unchanged for `debounceMs`, and centralize wet behavior:

```cpp
#include "LeakController.h"

bool LeakController::elapsed(uint32_t now, uint32_t since, uint32_t interval) {
  return static_cast<uint32_t>(now - since) >= interval;
}

void LeakController::enterWet(uint32_t nowMs) {
  const bool persistenceChanged = !leakLatched_ || requestedValve_ != ValveState::Closed;
  leakLatched_ = true;
  requestedValve_ = ValveState::Closed;
  valveState_ = ValveState::Closed;
  persistenceDirty_ = persistenceDirty_ || persistenceChanged;
  startAlarm(nowMs);
}

CommandResult LeakController::requestValve(ValveState requested, uint32_t nowMs) {
  (void)nowMs;
  if (requested == ValveState::Closed) {
    persistenceDirty_ = persistenceDirty_ || requestedValve_ != ValveState::Closed;
    requestedValve_ = ValveState::Closed;
    valveState_ = ValveState::Closed;
    return CommandResult::Accepted;
  }
  if (otaActive_) return CommandResult::RejectedOta;
  if (sensorState_ == SensorState::Uninitialized) return CommandResult::RejectedUninitialized;
  if (sensorState_ == SensorState::Wet) return CommandResult::RejectedWet;
  persistenceDirty_ = persistenceDirty_ || leakLatched_ || requestedValve_ != ValveState::Open;
  leakLatched_ = false;
  requestedValve_ = ValveState::Open;
  valveState_ = ValveState::Open;
  return CommandResult::Accepted;
}
```

Implement `restore()` so physical valve state remains closed until dry initialization; if the restored latch is true, start a fresh alarm. Implement `tick()` so timeout is based on `alarmDurationMs`, and implement beep phase as `(nowMs - alarmStartedMs_) % (beepOnMs + beepOffMs) < beepOnMs`, guarding against a zero period.

- [ ] **Step 5: Run the complete native suite and make all state tests pass**

Run: `scripts/run-native-tests.sh`

Expected: `All native tests passed`, with no compiler warnings. Confirm the added tests explicitly exercise a timestamp crossing `UINT32_MAX`.

- [ ] **Step 6: Commit the state machine when Git is available**

```bash
git add LeakController.h LeakController.cpp tests/native/test_main.cpp scripts/run-native-tests.sh
git commit -m "feat: add leak safety state machine"
```

---

### Task 2: Configuration Validation and Bearer Authentication

**Files:**
- Create: `DeviceConfig.h`
- Create: `DeviceConfig.cpp`
- Create: `Auth.h`
- Create: `Auth.cpp`
- Modify: `tests/native/test_main.cpp`
- Modify: `scripts/run-native-tests.sh`

**Interfaces:**
- Consumes: captive-portal character buffers and HTTP `Authorization` header text.
- Produces: `DeviceConfig`, `defaultDeviceConfig()`, `validateDeviceConfig(const DeviceConfig&)`, and `authorizeBearer(const char*, const char*)` for later network modules.

- [ ] **Step 1: Add failing configuration and authentication tests**

Append tests that assert exact defaults, boundary validation, mandatory token length, MQTT host requirement when enabled, and bearer parsing:

```cpp
#include "Auth.h"
#include "DeviceConfig.h"
#include <cstring>

static void testConfigValidation() {
  DeviceConfig cfg = defaultDeviceConfig();
  CHECK(!validateDeviceConfig(cfg).valid); // Default token is intentionally unset.
  std::strcpy(cfg.apiToken, "0123456789abcdef");
  CHECK(validateDeviceConfig(cfg).valid);
  cfg.dryThreshold = cfg.wetThreshold;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "thresholds") == 0);
  cfg = defaultDeviceConfig();
  std::strcpy(cfg.apiToken, "0123456789abcdef");
  cfg.mqttEnabled = true;
  CHECK(std::strcmp(validateDeviceConfig(cfg).field, "mqttHost") == 0);
}

static void testBearerAuthentication() {
  CHECK(authorizeBearer("Bearer 0123456789abcdef", "0123456789abcdef"));
  CHECK(!authorizeBearer("bearer 0123456789abcdef", "0123456789abcdef"));
  CHECK(!authorizeBearer("Bearer wrong", "0123456789abcdef"));
  CHECK(!authorizeBearer(nullptr, "0123456789abcdef"));
}
```

Run: `scripts/run-native-tests.sh`

Expected: compilation fails because `DeviceConfig.h` and `Auth.h` do not exist.

- [ ] **Step 2: Define bounded configuration data and exact validation ranges**

Create `DeviceConfig.h`:

```cpp
#pragma once
#include <stdint.h>

struct DeviceConfig {
  char deviceName[33];
  bool mqttEnabled;
  char mqttHost[65];
  uint16_t mqttPort;
  char mqttUser[33];
  char mqttPassword[65];
  char mqttBaseTopic[65];
  char apiToken[65];
  uint16_t wetThreshold;
  uint16_t dryThreshold;
  uint32_t debounceMs;
  uint32_t alarmDurationSeconds;
};

struct ConfigValidation {
  bool valid;
  const char* field;
};

DeviceConfig defaultDeviceConfig();
ConfigValidation validateDeviceConfig(const DeviceConfig& config);
```

Implement defaults in `DeviceConfig.cpp`: device name `water-sensor`, MQTT disabled, port `1883`, base topic `water-sensor`, empty secrets, wet `1200`, dry `600`, debounce `1000`, and alarm duration `180`. Accept ADC thresholds up to 4095, debounce 100–60000 ms, alarm duration 10–3600 seconds, MQTT port 1–65535, device/topic nonempty, token length 12–64, and require MQTT host only when MQTT is enabled. Always null-terminate copied portal strings.

- [ ] **Step 3: Implement bounded bearer parsing and timing-insensitive comparison**

Create `Auth.h` and `Auth.cpp`:

```cpp
// Auth.h
#pragma once
bool authorizeBearer(const char* authorizationHeader, const char* expectedToken);
```

```cpp
// Core comparison in Auth.cpp
#include "Auth.h"
#include <stddef.h>
#include <string.h>

bool authorizeBearer(const char* header, const char* expected) {
  static const char prefix[] = "Bearer ";
  if (!header || !expected || expected[0] == '\0') return false;
  if (strncmp(header, prefix, sizeof(prefix) - 1) != 0) return false;
  const char* supplied = header + sizeof(prefix) - 1;
  const size_t suppliedLen = strnlen(supplied, 65);
  const size_t expectedLen = strnlen(expected, 65);
  unsigned char diff = static_cast<unsigned char>(suppliedLen ^ expectedLen);
  for (size_t i = 0; i < 64; ++i) {
    const unsigned char a = i < suppliedLen ? static_cast<unsigned char>(supplied[i]) : 0;
    const unsigned char b = i < expectedLen ? static_cast<unsigned char>(expected[i]) : 0;
    diff |= static_cast<unsigned char>(a ^ b);
  }
  return diff == 0 && suppliedLen <= 64 && expectedLen <= 64;
}
```

- [ ] **Step 4: Compile the new native sources and pass all tests**

Add `DeviceConfig.cpp` and `Auth.cpp` to the `g++` command in `scripts/run-native-tests.sh`.

Run: `scripts/run-native-tests.sh`

Expected: `All native tests passed` with `-Werror` and no warnings.

- [ ] **Step 5: Commit configuration and auth when Git is available**

```bash
git add DeviceConfig.h DeviceConfig.cpp Auth.h Auth.cpp tests/native/test_main.cpp scripts/run-native-tests.sh
git commit -m "feat: add validated device configuration"
```

---

### Task 3: Arduino Build Foundation, Safe GPIO, and Preferences

**Files:**
- Create: `OutputLogic.h`
- Create: `HardwareConfig.h`
- Create: `ConfigStore.h`
- Create: `ConfigStore.cpp`
- Create: `water_sensor.ino`
- Create: `arduino-cli.yaml`
- Create: `.gitignore`

**Interfaces:**
- Consumes: `DeviceConfig`, `PersistentState`, and `LeakController` from Tasks 1–2.
- Produces: `ConfigStore::begin/loadConfig/saveConfig/loadState/saveState`, compile-time hardware constants, `applyValveOutput()`, `applyBuzzerOutput()`, and an ADC averaging loop for later services.

- [ ] **Step 1: Add local Arduino CLI configuration and pinned build inputs**

Create `arduino-cli.yaml`:

```yaml
board_manager:
  additional_urls:
    - https://espressif.github.io/arduino-esp32/package_esp32_index.json
directories:
  data: .arduino/data
  downloads: .arduino/staging
  user: .arduino/user
```

Create `.gitignore` containing:

```gitignore
.arduino/
.tools/
build/
*.bin
*.elf
```

If `arduino-cli` is unavailable, install the pinned Linux x86-64 binary into the ignored `.tools` directory and use `.tools/arduino-cli` for the commands below:

```bash
mkdir -p .tools
curl -fsSL https://github.com/arduino/arduino-cli/releases/download/v1.5.1/arduino-cli_1.5.1_Linux_64bit.tar.gz \
  | tar -xz -C .tools arduino-cli
```

Install packages outside project source control:

```bash
arduino-cli core update-index --config-file arduino-cli.yaml
arduino-cli core install esp32:esp32@3.3.11 --config-file arduino-cli.yaml
arduino-cli lib install "WiFiManager@2.0.17" "PubSubClient@2.8" "ArduinoJson@7.4.3" --config-file arduino-cli.yaml
```

Expected: all packages install under `.arduino/`.

- [ ] **Step 2: Define explicit ESP32-C3 hardware defaults**

Create platform-neutral `OutputLogic.h`:

```cpp
#pragma once
constexpr bool activeLevelFor(bool active, bool activeHigh) {
  return active == activeHigh;
}
```

Create `HardwareConfig.h`:

```cpp
#pragma once
#include "OutputLogic.h"
#include <Arduino.h>

namespace Hardware {
constexpr uint8_t SENSOR_ADC_PIN = 0;
constexpr uint8_t RELAY_PIN = 4;
constexpr uint8_t BUZZER_PIN = 5;
constexpr uint8_t CONFIG_BUTTON_PIN = 9;
constexpr bool RELAY_ACTIVE_HIGH = true;
constexpr bool BUZZER_ACTIVE_HIGH = true;
constexpr bool CONFIG_BUTTON_ACTIVE_LOW = true;
constexpr uint32_t SENSOR_SAMPLE_INTERVAL_MS = 50;
constexpr uint8_t SENSOR_AVERAGE_SAMPLES = 8;
constexpr uint32_t BUZZER_BEEP_ON_MS = 500;
constexpr uint32_t BUZZER_BEEP_OFF_MS = 500;
constexpr char FIRMWARE_VERSION[] = "1.0.0";

inline uint8_t outputLevel(bool active, bool activeHigh) {
  return activeLevelFor(active, activeHigh) ? HIGH : LOW;
}
}
```

Include `OutputLogic.h` in the native test and assert `activeLevelFor(true, true)`, `!activeLevelFor(false, true)`, `!activeLevelFor(true, false)`, and `activeLevelFor(false, false)` to cover the actual mapping used by the sketch.

- [ ] **Step 3: Add explicit Preferences serialization**

Create `ConfigStore.h` with:

```cpp
#pragma once
#include "DeviceConfig.h"
#include "LeakController.h"
#include <Preferences.h>

class ConfigStore {
 public:
  bool begin();
  DeviceConfig loadConfig() const;
  bool saveConfig(const DeviceConfig& config);
  PersistentState loadState() const;
  bool saveState(const PersistentState& state);
 private:
  mutable Preferences preferences_;
};
```

In `ConfigStore.cpp`, use namespaces `watercfg` and `waterstate`, a schema key `version` with value `1`, and explicit keys rather than dumping raw structs. Use `getString(...).toCharArray(...)` for every string, `putString` for strings, `putBool`/`putUShort`/`putULong` for scalar configuration, and store valve as `uint8_t`. If the schema is absent, return `defaultDeviceConfig()` and `{false, ValveState::Open}`. Save only validated configurations.

- [ ] **Step 4: Build the safe sketch skeleton and sensor averaging loop**

Create `water_sensor.ino`. Keep the controller and service objects in `std::unique_ptr` instances because validated settings are loaded during `setup()`. In `setup()`, drive the relay to its active/valve-closed level and the buzzer to its inactive level before starting Serial or networking; construct `LeakConfig` from stored settings; allocate and restore the controller; and set ADC resolution to 12 bits. In `loop()`, sample every 50 ms, update after 8 samples, tick the controller, persist only when `takePersistentDirty()` returns true, and apply both outputs every pass:

```cpp
void applyOutputs(uint32_t nowMs) {
  digitalWrite(Hardware::RELAY_PIN,
      Hardware::outputLevel(controller.valveState() == ValveState::Closed,
                            Hardware::RELAY_ACTIVE_HIGH));
  digitalWrite(Hardware::BUZZER_PIN,
      Hardware::outputLevel(controller.buzzerOutput(nowMs),
                            Hardware::BUZZER_ACTIVE_HIGH));
}

void sampleSensor(uint32_t nowMs) {
  if (static_cast<uint32_t>(nowMs - lastSampleMs) < Hardware::SENSOR_SAMPLE_INTERVAL_MS) return;
  lastSampleMs = nowMs;
  sampleSum += analogRead(Hardware::SENSOR_ADC_PIN);
  if (++sampleCount == Hardware::SENSOR_AVERAGE_SAMPLES) {
    latestAdc = static_cast<uint16_t>(sampleSum / sampleCount);
    controller.updateSensor(latestAdc, nowMs);
    sampleSum = 0;
    sampleCount = 0;
  }
}
```

- [ ] **Step 5: Compile the embedded skeleton**

Run:

```bash
arduino-cli compile --config-file arduino-cli.yaml \
  --fqbn esp32:esp32:esp32c3:PartitionScheme=default \
  --output-dir build .
```

Expected: successful ESP32-C3 compilation and a `build/water_sensor.ino.bin` artifact. Also rerun `scripts/run-native-tests.sh` and expect all tests to pass.

- [ ] **Step 6: Commit the hardware foundation when Git is available**

```bash
git add OutputLogic.h HardwareConfig.h ConfigStore.h ConfigStore.cpp water_sensor.ino arduino-cli.yaml .gitignore tests/native/test_main.cpp
git commit -m "feat: add esp32 hardware and persistence foundation"
```

---

### Task 4: Non-Blocking Captive Portal

**Files:**
- Create: `NetworkConfig.h`
- Create: `NetworkConfig.cpp`
- Modify: `water_sensor.ino`

**Interfaces:**
- Consumes: current `DeviceConfig`, config-button state, WiFiManager, and `ConfigStore::saveConfig`.
- Produces: `NetworkConfig::begin(DeviceConfig&, bool)`, `process()`, `wifiConnected()`, `portalActive()`, and `takeConfigChanged(DeviceConfig&)`.

- [ ] **Step 1: Define portal ownership and stable parameter buffers**

Create `NetworkConfig.h` with a `WiFiManager` member and long-lived `WiFiManagerParameter` members/buffers for device name, MQTT enable/host/port/user/password/topic, API token, wet/dry thresholds, debounce milliseconds, and alarm seconds. Expose:

```cpp
class NetworkConfig {
 public:
  NetworkConfig();
  void begin(DeviceConfig& config, bool forcePortal);
  void process();
  bool wifiConnected() const;
  bool portalActive() const;
  bool takeConfigChanged(DeviceConfig& output);
 private:
  static NetworkConfig* callbackOwner_;
  static void onSaveStatic();
  void onSave();
  void copyConfigToBuffers(const DeviceConfig& config);
  bool copyBuffersToConfig(DeviceConfig& output) const;
  WiFiManager wifiManager_;
  WiFiManagerParameter deviceNameParam_;
  WiFiManagerParameter mqttEnabledParam_;
  WiFiManagerParameter mqttHostParam_;
  WiFiManagerParameter mqttPortParam_;
  WiFiManagerParameter mqttUserParam_;
  WiFiManagerParameter mqttPasswordParam_;
  WiFiManagerParameter mqttTopicParam_;
  WiFiManagerParameter apiTokenParam_;
  WiFiManagerParameter wetThresholdParam_;
  WiFiManagerParameter dryThresholdParam_;
  WiFiManagerParameter debounceParam_;
  WiFiManagerParameter alarmDurationParam_;
  DeviceConfig currentConfig_;
  DeviceConfig pendingConfig_;
  bool portalActive_;
  bool configChanged_;
};
```

- [ ] **Step 2: Implement a non-blocking first-run and forced portal**

In `begin()`, call `setConfigPortalBlocking(false)`, `setConfigPortalTimeout(300)`, register the save callback, and add every parameter before calling either `startConfigPortal(apName)` when `forcePortal` is true or `autoConnect(apName)` otherwise. Generate `apName` as `<deviceName>-setup`. Render MQTT password and API token parameters with `type="password"`; an empty submitted secret keeps an existing stored secret, but the first configuration cannot save without a 12-character API token.

In `process()`, call `wifiManager_.process()` once per main-loop pass. In `onSave()`, parse integers with `strtoul` plus complete-string/end-range checks, construct a candidate, call `validateDeviceConfig`, and only set the pending-change flag for a valid candidate.

- [ ] **Step 3: Integrate portal processing without delaying safety work**

In `setup()`, read `CONFIG_BUTTON_PIN` after `INPUT_PULLUP`; derive `forcePortal` from `CONFIG_BUTTON_ACTIVE_LOW`; start `NetworkConfig` only after the controller and safe outputs exist. In `loop()`, order operations as sensor sample → controller tick → outputs → network portal process → config persistence. When a valid configuration arrives, persist it and reboot after 500 ms so all services reconstruct consistently; keep the valve closed during that scheduled reboot.

- [ ] **Step 4: Compile and manually inspect the loop for blocking calls**

Run native tests and the ESP32-C3 compile command from Task 3. Then run:

```bash
rg -n 'delay\(|while\s*\(' water_sensor.ino NetworkConfig.cpp
```

Expected: no `delay()` and no connection-wait loop. Any bounded parsing loop must be visibly unrelated to time/network waiting.

- [ ] **Step 5: Commit captive-portal provisioning when Git is available**

```bash
git add NetworkConfig.h NetworkConfig.cpp water_sensor.ino
git commit -m "feat: add captive portal provisioning"
```

---

### Task 5: Shared Status JSON and Authenticated HTTP Control

**Files:**
- Create: `StatusJson.h`
- Create: `StatusJson.cpp`
- Create: `HttpApi.h`
- Create: `HttpApi.cpp`
- Modify: `water_sensor.ino`

**Interfaces:**
- Consumes: `DeviceConfig`, `LeakController`, latest ADC, Wi-Fi/MQTT state callback, uptime, and `authorizeBearer`.
- Produces: `buildStatusJson(...)`, `HttpApi::begin()`, `handleClient()`, and authenticated valve/buzzer endpoints.

- [ ] **Step 1: Define one runtime-status snapshot for HTTP and MQTT**

Create `StatusJson.h`:

```cpp
#pragma once
#include "DeviceConfig.h"
#include "LeakController.h"
#include <Arduino.h>
#include <functional>

struct RuntimeStatus {
  uint32_t uptimeMs;
  uint16_t sensorAdc;
  bool wifiConnected;
  int32_t wifiRssi;
  bool mqttConnected;
  bool otaInProgress;
};

using RuntimeStatusProvider = std::function<RuntimeStatus()>;
using StateChangeCallback = std::function<void()>;

String buildStatusJson(const DeviceConfig& config,
                       const LeakController& controller,
                       const RuntimeStatus& runtime,
                       uint32_t nowMs);
```

Implement with ArduinoJson 7 `JsonDocument`, explicit enum-to-lowercase-string helpers, and `serializeJson`. Include firmware/device, uptime, ADC, initialized/stable sensor state, thresholds, latch, requested/applied valve and relay active state, alarm state/sounding/remaining seconds, Wi-Fi/RSSI, MQTT enabled/connected, and OTA state. Do not add credential fields.

- [ ] **Step 2: Define HTTP ownership and response helpers**

Create `HttpApi.h` with this public interface; Task 6 extends it with OTA methods and fields:

```cpp
class HttpApi {
 public:
  HttpApi(const DeviceConfig& config, LeakController& controller,
          ConfigStore& store, RuntimeStatusProvider statusProvider,
          StateChangeCallback stateChanged);
  void begin();
  void handleClient();
 private:
  bool authorized() const;
  void sendJsonError(int status, const char* error, const char* message);
  void sendStatus(int status = 200);
  void handleValve();
  void handleBuzzer();
  const DeviceConfig& config_;
  LeakController& controller_;
  ConfigStore& store_;
  RuntimeStatusProvider statusProvider_;
  StateChangeCallback stateChanged_;
  WebServer server_{80};
};
```

In `begin()`, call `server_.collectHeaders()` with an array containing the single `Authorization` header, then register routes and `server_.begin()`.

- [ ] **Step 3: Implement status and control routes**

Register exact behavior:

```cpp
server_.on("/api/status", HTTP_GET, [this] { sendStatus(); });
server_.on("/api/valve", HTTP_POST, [this] { handleValve(); });
server_.on("/api/buzzer", HTTP_POST, [this] { handleBuzzer(); });
```

Use ArduinoJson to parse `server_.arg("plain")` with a bounded document. Require bearer auth before parsing mutations. Map `CommandResult::RejectedWet`, `RejectedUninitialized`, and `RejectedOta` to HTTP 409 with stable error keys `sensor_wet`, `sensor_uninitialized`, and `ota_active`. Accept only lowercase-normalized `open`/`closed` and `silence`. Persist immediately after accepted valve changes and notify MQTT through the callback.

- [ ] **Step 4: Integrate and exercise HTTP locally on hardware**

Call `httpApi.handleClient()` once each loop after applying outputs. Compile, flash, and run:

```bash
curl -sS http://DEVICE_IP/api/status | jq .
curl -i -X POST http://DEVICE_IP/api/valve -H 'Content-Type: application/json' -d '{"state":"closed"}'
curl -i -X POST http://DEVICE_IP/api/valve -H 'Authorization: Bearer TEST_TOKEN' -H 'Content-Type: application/json' -d '{"state":"closed"}'
curl -i -X POST http://DEVICE_IP/api/buzzer -H 'Authorization: Bearer TEST_TOKEN' -H 'Content-Type: application/json' -d '{"command":"silence"}'
```

Expected: status contains no secrets; unauthenticated close is 401; authenticated close and silence are 200; authenticated open is 409 until a stable dry state exists.

- [ ] **Step 5: Commit HTTP control when Git is available**

```bash
git add StatusJson.h StatusJson.cpp HttpApi.h HttpApi.cpp water_sensor.ino
git commit -m "feat: add authenticated http control api"
```

---

### Task 6: Authenticated Streaming Web OTA

**Files:**
- Modify: `HttpApi.h`
- Modify: `HttpApi.cpp`
- Modify: `water_sensor.ino`

**Interfaces:**
- Consumes: bearer auth, `LeakController::setOtaActive`, close command/persistence, ESP32 `Update`, and loop timestamp.
- Produces: `GET /update`, streaming `POST /api/ota`, `HttpApi::otaInProgress() const`, and `HttpApi::rebootDue(uint32_t) const`.

- [ ] **Step 1: Add OTA state fields and an embedded upload page**

Add public `bool otaInProgress() const` and `bool rebootDue(uint32_t nowMs) const`; private `handleOtaChunk()` and `finishOtaRequest()`; and fields `otaAuthorized_`, `otaFailed_`, `otaError_[96]`, `rebootScheduled_`, and `rebootAtMs_`. Store the page in flash with `PROGMEM`; its form must read a token and `.bin`, then call `fetch('/api/ota', {method:'POST', headers:{Authorization:'Bearer '+token}, body:formData})`, display the returned JSON/text, and never use local storage.

- [ ] **Step 2: Register streaming OTA handlers with auth before writes**

Use the two-callback `WebServer::on` upload form:

```cpp
server_.on("/api/ota", HTTP_POST,
  [this] { finishOtaRequest(); },
  [this] { handleOtaChunk(); });
```

At `UPLOAD_FILE_START`, authenticate, set OTA active, request/persist valve closed, notify state change, and call `Update.begin(UPDATE_SIZE_UNKNOWN, U_FLASH)`. At `UPLOAD_FILE_WRITE`, require authorization and exact `Update.write(upload.buf, upload.currentSize) == upload.currentSize`. At `UPLOAD_FILE_END`, require `Update.end(true)`. Copy `Update.errorString()` into the bounded error buffer on failure. Never log the header/token.

In the final handler, return 401 for failed auth, 500 with `ota_failed` and the bounded update error for update failure, or 200 with `{"ok":true,"rebooting":true}` and schedule reboot for 500 ms later. Do not reboot from the upload callback.

- [ ] **Step 3: Keep the valve closed on every OTA outcome**

Expose OTA state through the runtime snapshot. Reject valve-open commands throughout upload. On failed upload, clear the OTA-active interlock only after the response but leave the requested valve state closed; on success keep it active until restart. In `loop()`, call `ESP.restart()` only when `rebootDue(millis())` is true, after outputs and `handleClient()` have run.

- [ ] **Step 4: Compile and test both rejection and success paths on hardware**

Build the sketch, then run:

```bash
curl -i -X POST -F 'firmware=@build/water_sensor.ino.bin' http://DEVICE_IP/api/ota
curl -i -X POST -H 'Authorization: Bearer TEST_TOKEN' -F 'firmware=@docs/superpowers/specs/2026-09-02-esp32-c3-water-leak-controller-design.md' http://DEVICE_IP/api/ota
curl -i -X POST -H 'Authorization: Bearer TEST_TOKEN' -F 'firmware=@build/water_sensor.ino.bin' http://DEVICE_IP/api/ota
```

Expected: first request is 401 and writes nothing; invalid image returns an OTA error and valve remains closed; valid image returns 200, closes/persists the valve, reboots, and reports the expected firmware version afterward.

- [ ] **Step 5: Commit OTA support when Git is available**

```bash
git add HttpApi.h HttpApi.cpp water_sensor.ino
git commit -m "feat: add authenticated web ota updates"
```

---

### Task 7: MQTT Status, Commands, and Reconnect Backoff

**Files:**
- Create: `MqttService.h`
- Create: `MqttService.cpp`
- Modify: `water_sensor.ino`

**Interfaces:**
- Consumes: `DeviceConfig`, `LeakController`, `ConfigStore`, `buildStatusJson`, runtime snapshot callback, and Wi-Fi state.
- Produces: `MqttService::begin()`, `process(uint32_t)`, `connected()`, `requestStatusPublish()`, retained availability/status, valve/buzzer commands, and command-result JSON.

- [ ] **Step 1: Define bounded MQTT topics and service state**

Create `MqttService.h` with this public interface:

```cpp
class MqttService {
 public:
  MqttService(const DeviceConfig& config, LeakController& controller,
              ConfigStore& store, RuntimeStatusProvider statusProvider);
  void begin();
  void process(uint32_t nowMs);
  bool connected() const;
  void requestStatusPublish();
 private:
  void handleMessage(char* topic, uint8_t* payload, unsigned int length);
  bool connect(uint32_t nowMs);
  bool publishStatus(uint32_t nowMs);
  void publishResult(const char* command, bool accepted, const char* detail);
  const DeviceConfig& config_;
  LeakController& controller_;
  ConfigStore& store_;
  RuntimeStatusProvider statusProvider_;
  WiFiClient wifiClient_;
  PubSubClient mqttClient_;
  char availabilityTopic_[96];
  char statusTopic_[96];
  char valveCommandTopic_[96];
  char buzzerCommandTopic_[96];
  char resultTopic_[96];
  uint32_t nextConnectMs_;
  uint32_t reconnectDelayMs_;
  uint32_t lastStatusMs_;
  bool statusDirty_;
  bool topicsValid_;
};
```

Build exact topics `<base>/availability`, `<base>/status`, `<base>/valve/set`, `<base>/buzzer/set`, and `<base>/command/result`; reject configuration if any formatted topic truncates. Set MQTT buffer size to 1024, keepalive to 30 seconds, and socket timeout to 2 seconds.

- [ ] **Step 2: Implement capped non-blocking reconnect scheduling**

In `process(nowMs)`, return immediately when MQTT is disabled, Wi-Fi is down, or the next attempt is not due. On connection failure, schedule delays 1000, 2000, 4000, 8000, 16000, then 30000 ms; do not loop. Connect with a client ID composed from sanitized device name plus the low 24 bits of `ESP.getEfuseMac()`, username/password only when configured, and retained last will `offline`. On success publish retained `online`, subscribe to both command topics at QoS 1, reset backoff, and publish status.

- [ ] **Step 3: Route MQTT commands through the same controller methods**

Copy callback payloads into a bounded local buffer, trim ASCII whitespace, uppercase in place, and accept only `OPEN`, `CLOSE`, and `SILENCE` on their matching topics. Persist accepted valve changes. Publish non-retained result JSON with fields `command`, `accepted`, and either `state` or `error`; then request an immediate retained status publication. Never include credentials/token.

- [ ] **Step 4: Publish state changes and heartbeat**

Publish retained status when dirty and every 60 seconds. Use the exact JSON from `buildStatusJson`. If serialization exceeds the MQTT buffer, publish a bounded result error and retain the dirty flag for retry. Call `mqttClient_.loop()` at most once per main-loop pass.

- [ ] **Step 5: Compile and verify with a broker**

Run native tests and ESP32 compile. With a test broker:

```bash
mosquitto_sub -h BROKER -u USER -P PASS -v -t 'water-sensor/#'
mosquitto_pub -h BROKER -u USER -P PASS -t 'water-sensor/valve/set' -m CLOSE
mosquitto_pub -h BROKER -u USER -P PASS -t 'water-sensor/buzzer/set' -m SILENCE
mosquitto_pub -h BROKER -u USER -P PASS -t 'water-sensor/valve/set' -m OPEN
```

Expected: retained availability/status appear; close and silence succeed; open is rejected while wet/uninitialized and succeeds only while dry; stopping the device ungracefully produces retained `offline`; reconnection republishes `online` and current status.

- [ ] **Step 6: Commit MQTT support when Git is available**

```bash
git add MqttService.h MqttService.cpp water_sensor.ino
git commit -m "feat: add mqtt status and control"
```

---

### Task 8: Documentation and End-to-End Verification

**Files:**
- Create: `README.md`
- Modify: any implementation file only for defects exposed by verification.

**Interfaces:**
- Consumes: all completed firmware behavior.
- Produces: reproducible Arduino IDE/CLI setup, wiring/calibration/API/MQTT/OTA instructions, explicit limitations, and final evidence.

- [ ] **Step 1: Write exact wiring and electrical warnings**

Document the default mapping GPIO0 sensor ADC, GPIO4 relay input, GPIO5 active-buzzer driver, and GPIO9 boot/config button. Show sensor 3.3 V/GND/signal wiring; shared ground; relay-module input only; transistor/flyback requirements for raw relay or buzzer loads; contact voltage/current rating; and the active-HIGH configuration constants. State plainly that an energized-to-close valve may reopen on total power loss.

- [ ] **Step 2: Document provisioning, calibration, and recovery**

Explain first-run `<device>-setup` captive portal, mandatory 12–64 character token, optional MQTT, holding the configured button at boot to reopen the portal, and how to read dry/wet ADC values from `/api/status`. Give a concrete calibration example: dry 180 and immersed 1680 → dry threshold 400, wet threshold 1000. Explain corrosion and that disconnected and dry can both read near zero.

- [ ] **Step 3: Document exact HTTP, MQTT, and OTA examples**

Include the `curl` and `mosquitto_*` commands from Tasks 5–7 with documented metavariables `DEVICE_IP`, `API_TOKEN`, `BROKER`, `USER`, and `PASS`; list every JSON field/error and topic. Explain that commands should not be retained. Describe browser `/update` and `curl` OTA, the OTA-capable partition requirement, forced valve closure, and trusted-LAN/VLAN limitation.

- [ ] **Step 4: Run warning-clean native and embedded builds from scratch**

Run:

```bash
scripts/run-native-tests.sh
arduino-cli compile --config-file arduino-cli.yaml \
  --fqbn esp32:esp32:esp32c3:PartitionScheme=default \
  --warnings all --output-dir build .
```

Expected: native tests report `All native tests passed`; embedded compile exits zero with no project-source warnings; binary fits both flash and RAM limits.

- [ ] **Step 5: Audit safety, secrets, and blocking behavior**

Run:

```bash
rg -n 'delay\(|while\s*\(|apiToken|mqttPassword|Authorization' --glob '*.{ino,h,cpp}'
rg -n 'Serial\.(print|printf).*token|Serial\.(print|printf).*password' --glob '*.{ino,h,cpp}'
```

Expected: no blocking wait/delay, no secret logging, all mutating HTTP handlers call `authorized()`, OTA authenticates before `Update.begin`, and MQTT payloads never contain the HTTP token.

- [ ] **Step 6: Execute and record the hardware checklist**

Verify each item from the design spec: dry/wet calibration; relay polarity; boot-safe closure; offline wet closure/latching; wet-open rejection; no dry auto-open; authenticated dry-open; invalid-token rejection; buzzer silence/timeout independence; alarm restart after dry-to-wet; OTA closure/reboot; MQTT last will/recovery. Record observed ADC thresholds, board model, valve type, relay level, and firmware version in a dated “Installation record” section or a separate private deployment note if those values should not enter source control.

- [ ] **Step 7: Commit documentation when Git is available**

```bash
git add README.md
git commit -m "docs: add installation and api guide"
```

- [ ] **Step 8: Inspect final workspace state**

Run: `git status --short` when Git exists, otherwise `find . -maxdepth 3 -type f -not -path './.arduino/*' -not -path './build/*' | sort`.

Expected: only intended source, tests, docs, configuration, and ignored build artifacts exist; no credentials or deployment secrets are present.

#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "$1" >&2
  exit 1
}

# UART0 carries the CO sensor, so a build without USB CDC must not compile.
grep -q 'ARDUINO_USB_CDC_ON_BOOT != 1' "$repo_dir/HardwareConfig.h" ||
  fail "The USB CDC build guard is gone; UART0 would become the console."
grep -q '^#error' "$repo_dir/HardwareConfig.h" ||
  fail "The USB CDC build guard no longer fails the build."

# Serial2 defaults to GPIO19/20, which are the USB data pins, so opening a
# sensor UART without explicit pins would silently detach the USB console.
for uart in coSerial presenceSerial particulateSerial; do
  grep -Eq "${uart}\.begin\(.*SERIAL_8N1," "$repo_dir/air_sensor.ino" ||
    fail "${uart} is not opened with explicit RX/TX pins."
done

# Network-facing services must not start concurrently with WiFiManager's
# initialization task. The safety loop waits for an explicit ready handoff.
grep -q 'bool ready() const;' "$repo_dir/NetworkConfig.h" ||
  fail "NetworkConfig no longer exposes its initialization handoff."
grep -q 'ready_\.store(true' "$repo_dir/NetworkConfig.cpp" ||
  fail "The network task no longer publishes initialization completion."
grep -q 'networkConfig->ready()' "$repo_dir/air_sensor.ino" ||
  fail "HTTP/MQTT services can start before network initialization completes."

# The octal-PSRAM hazard on the LED pins must stay documented next to the pins
# and in the setup instructions.
grep -q 'Octal SPI PSRAM' "$repo_dir/HardwareConfig.h" ||
  fail "The octal-PSRAM LED pin warning left HardwareConfig.h."
grep -qi 'octal' "$repo_dir/README.md" ||
  fail "The octal-PSRAM LED pin warning left the README."

# This unit is wired to the octal-PSRAM-safe LED pins. Keep the compiled
# pinout aligned with the physical red/green/blue connections.
grep -q '^constexpr uint8_t LED_RED_PIN = 21;' "$repo_dir/HardwareConfig.h" ||
  fail "Red LED is not assigned to the wired GPIO21 pin."
grep -q '^constexpr uint8_t LED_GREEN_PIN = 47;' "$repo_dir/HardwareConfig.h" ||
  fail "Green LED is not assigned to the wired GPIO47 pin."
grep -q '^constexpr uint8_t LED_BLUE_PIN = 48;' "$repo_dir/HardwareConfig.h" ||
  fail "Blue LED is not assigned to the wired GPIO48 pin."

# Silencing and OTA are buzzer-scope actions. Neither may reach the visual
# alarm, and neither may suppress a live hazard.
if awk '/^LedColor AirController::ledColor/,/^}/' "$repo_dir/AirController.cpp" |
    grep -q 'silenceActive_\|otaActive_'; then
  fail "Silencing or OTA now suppresses the visual alarm."
fi

if awk '/^bool AirController::buzzerOutput/,/^}/' "$repo_dir/AirController.cpp" |
    grep -q 'otaActive_'; then
  fail "OTA state reached the buzzer output path."
fi

# The alarm is level-based on purpose: no latch may creep back in.
if grep -q 'leakLatched\|latched_' "$repo_dir/AirController.cpp"; then
  fail "A latch reappeared in the air controller."
fi

# Warm-up must gate every hazard channel, not just the heated gas sensor.
for observer in observeCo observeGas observeParticulate; do
  awk "/^ChannelState AirController::${observer}/,/^}/" "$repo_dir/AirController.cpp" |
    grep -q 'warmingUp' ||
    fail "${observer} no longer suppresses readings during warm-up."
done

echo "Canary safety invariants hold."

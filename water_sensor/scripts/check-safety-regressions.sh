#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rg -q 'CONFIG_BUTTON_PIN = 10;' "$repo_dir/HardwareConfig.h"
rg -q '\| Boot/config button \| GPIO10 \|' "$repo_dir/README.md"
if rg --pcre2 -U -qi '(?s)GPIO ?9[^.]{0,100}GND|GND[^.]{0,100}GPIO ?9' "$repo_dir/README.md"; then
  echo "README still prescribes GPIO9-to-GND boot recovery" >&2
  exit 1
fi

if rg -q 'WiFi\.RSSI\(' "$repo_dir/water_sensor.ino"; then
  echo "Main loop reads Wi-Fi telemetry owned by the network task" >&2
  exit 1
fi

setup_body="$(sed -n '/^void setup()/,/^void loop()/p' "$repo_dir/water_sensor.ino")"
if grep -q 'httpApi->begin()' <<<"$setup_body"; then
  echo "HTTP server starts before asynchronous Wi-Fi initialization completes" >&2
  exit 1
fi

if rg -q 'NETWORK_TASK_PRIORITY = tskIDLE_PRIORITY;' \
  "$repo_dir/NetworkConfig.cpp" "$repo_dir/MqttService.cpp"; then
  echo "Network worker can be starved by Arduino loopTask priority" >&2
  exit 1
fi

if ! rg -q 'WiFi\.setTxPower\(WIFI_POWER_8_5dBm\)' \
  "$repo_dir/NetworkConfig.cpp"; then
  echo "ESP32-C3 portal does not apply the low-power SoftAP compatibility setting" >&2
  exit 1
fi

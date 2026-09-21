#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${TMPDIR:-/tmp}"

common_flags=(-std=c++17 -Wall -Wextra -Werror -pedantic -I"$repo_dir")

safety_binary="$out_dir/canary-native-tests"
g++ "${common_flags[@]}" -I"$repo_dir/tests/native/stubs" \
  "$repo_dir/DeviceConfig.cpp" \
  "$repo_dir/Auth.cpp" \
  "$repo_dir/AirController.cpp" \
  "$repo_dir/MqttService.cpp" \
  "$repo_dir/tests/native/MqttServiceTestStubs.cpp" \
  "$repo_dir/tests/native/test_main.cpp" \
  -o "$safety_binary"
"$safety_binary"

readers_binary="$out_dir/canary-reader-frame-tests"
g++ "${common_flags[@]}" \
  "$repo_dir/Ze03Reader.cpp" \
  "$repo_dir/Pms5003Reader.cpp" \
  "$repo_dir/Ld2410Reader.cpp" \
  "$repo_dir/tests/native/reader_frames_test.cpp" \
  -o "$readers_binary"
"$readers_binary"

config_binary="$out_dir/canary-config-store-fallback-test"
g++ "${common_flags[@]}" -I"$repo_dir/tests/native/stubs" \
  "$repo_dir/DeviceConfig.cpp" \
  "$repo_dir/ConfigStore.cpp" \
  "$repo_dir/tests/native/config_store_fallback_test.cpp" \
  -o "$config_binary"
"$config_binary"

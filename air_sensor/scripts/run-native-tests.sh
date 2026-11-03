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

hub_host_binary="$out_dir/canary-hub-host-tests"
g++ "${common_flags[@]}" \
  "$repo_dir/tests/native/hub_host_test.cpp" \
  -o "$hub_host_binary"
"$hub_host_binary"

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

display_binary="$out_dir/canary-display-model-test"
g++ "${common_flags[@]}" \
  "$repo_dir/AirController.cpp" \
  "$repo_dir/DisplayModel.cpp" \
  "$repo_dir/tests/native/display_model_test.cpp" \
  -o "$display_binary"
"$display_binary"

detector_binary="$out_dir/canary-gas-detector-input-test"
g++ "${common_flags[@]}" \
  "$repo_dir/GasDetectorInput.cpp" \
  "$repo_dir/tests/native/gas_detector_input_test.cpp" \
  -o "$detector_binary"
"$detector_binary"

mesh_binary="$out_dir/canary-mesh-frame-test"
g++ "${common_flags[@]}" \
  "$repo_dir/tests/native/mesh_frame_test.cpp" \
  -o "$mesh_binary"
"$mesh_binary"

# Water and air nodes relay each other's frames: the mesh code must match.
for file in MeshFrame.h MeshLink.h MeshLink.cpp; do
  if ! cmp -s "$repo_dir/$file" "$repo_dir/../water_sensor/$file"; then
    echo "$file differs from ../water_sensor/$file" >&2
    exit 1
  fi
done

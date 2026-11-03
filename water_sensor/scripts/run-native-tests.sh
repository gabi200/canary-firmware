#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary_path="${TMPDIR:-/tmp}/water-sensor-native-tests"
g++ -std=c++17 -Wall -Wextra -Werror -pedantic -I"$repo_dir" \
  -I"$repo_dir/tests/native/mqtt_stubs" \
  "$repo_dir/DeviceConfig.cpp" \
  "$repo_dir/Auth.cpp" \
  "$repo_dir/LeakController.cpp" \
  "$repo_dir/MqttService.cpp" \
  "$repo_dir/tests/native/MqttServiceTestStubs.cpp" \
  "$repo_dir/tests/native/test_main.cpp" \
  -o "$binary_path"
"$binary_path"

config_store_binary_path="${TMPDIR:-/tmp}/water-sensor-config-store-fallback-test"
g++ -std=c++17 -Wall -Wextra -Werror -pedantic -I"$repo_dir" \
  -I"$repo_dir/tests/native/mqtt_stubs" \
  "$repo_dir/DeviceConfig.cpp" \
  "$repo_dir/LeakController.cpp" \
  "$repo_dir/ConfigStore.cpp" \
  "$repo_dir/tests/native/config_store_fallback_test.cpp" \
  -o "$config_store_binary_path"
"$config_store_binary_path"

mesh_binary_path="${TMPDIR:-/tmp}/water-sensor-mesh-frame-test"
g++ -std=c++17 -Wall -Wextra -Werror -pedantic -I"$repo_dir" \
  "$repo_dir/tests/native/mesh_frame_test.cpp" \
  -o "$mesh_binary_path"
"$mesh_binary_path"

# Water and air nodes relay each other's frames and find the hub the same way: these must match.
for file in MeshFrame.h MeshLink.h MeshLink.cpp HubHost.h; do
  if ! cmp -s "$repo_dir/$file" "$repo_dir/../air_sensor/$file"; then
    echo "$file differs from ../air_sensor/$file" >&2
    exit 1
  fi
done

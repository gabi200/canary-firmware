#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

rg -q 'CONFIG_BUTTON_PIN = 10;' "$repo_dir/HardwareConfig.h"
rg -q '\| Boot/config button \| GPIO10 \|' "$repo_dir/README.md"
if rg --pcre2 -U -qi '(?s)GPIO ?9[^.]{0,100}GND|GND[^.]{0,100}GPIO ?9' "$repo_dir/README.md"; then
  echo "README still prescribes GPIO9-to-GND boot recovery" >&2
  exit 1
fi

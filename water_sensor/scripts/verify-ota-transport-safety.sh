#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
header="$repo_dir/HttpApi.h"
implementation="$repo_dir/HttpApi.cpp"

if rg -q 'WebServer' "$header" "$implementation"; then
  echo "Unsafe: OTA must use HttpApi's incremental NetworkServer transport." >&2
  exit 1
fi

if ! rg -q 'bool otaInProgress\(\) const' "$header" ||
   ! rg -q 'bool rebootDue\(uint32_t nowMs\) const' "$header"; then
  echo "OTA runtime/restart interfaces are missing." >&2
  exit 1
fi

if ! rg -q '#include <Update.h>' "$implementation" ||
   ! rg -q 'Update\.begin' "$implementation" ||
   ! rg -q 'Update\.write' "$implementation" ||
   ! rg -q 'Update\.end' "$implementation"; then
  echo "Authenticated streaming Update lifecycle is incomplete." >&2
  exit 1
fi

if ! rg -q 'MAX_BYTES_PER_HANDLE' "$implementation" ||
   ! rg -q 'authorizeBearer' "$implementation"; then
  echo "OTA is not guarded by the bounded authenticated transport." >&2
  exit 1
fi

echo "OTA stays on the bounded, authenticated incremental transport."

#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
header="$repo_dir/HttpApi.h"
implementation="$repo_dir/HttpApi.cpp"

# Strip comments first: the header explains why WebServer is avoided, and that
# explanation must not read as a use of it.
if sed 's,//.*,,' "$header" "$implementation" |
    grep -Eq '#include[[:space:]]*<WebServer\.h>|\bWebServer[[:space:]]+[A-Za-z_]'; then
  echo "Unsafe: OTA must use HttpApi's incremental NetworkServer transport." >&2
  exit 1
fi

if ! grep -q 'bool otaInProgress() const' "$header" ||
   ! grep -q 'bool rebootDue(uint32_t nowMs) const' "$header"; then
  echo "OTA runtime/restart interfaces are missing." >&2
  exit 1
fi

if ! grep -q '#include <Update.h>' "$implementation" ||
   ! grep -q 'Update\.begin' "$implementation" ||
   ! grep -q 'Update\.write' "$implementation" ||
   ! grep -q 'Update\.end' "$implementation"; then
  echo "Authenticated streaming Update lifecycle is incomplete." >&2
  exit 1
fi

if ! grep -q 'MAX_BYTES_PER_HANDLE' "$implementation" ||
   ! grep -q 'authorizeBearer' "$implementation"; then
  echo "OTA is not guarded by the bounded authenticated transport." >&2
  exit 1
fi

# An update must not become a way to silence a live hazard alarm.
if awk '/^void HttpApi::beginOtaRequest/,/^}/' "$implementation" |
    grep -q 'silenceAlarm\|startSelfTest'; then
  echo "Starting an OTA now changes the alarm state." >&2
  exit 1
fi

echo "OTA stays on the bounded, authenticated incremental transport."

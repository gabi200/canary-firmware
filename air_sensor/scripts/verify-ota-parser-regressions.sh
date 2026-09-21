#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
implementation="$repo_dir/HttpApi.cpp"

file_matcher="$(sed -n '/bool HttpApi::handleOtaFileByte/,/^}/p' "$implementation")"
if grep -q 'return handleOtaFileByte(byte)' <<<"$file_matcher"; then
  echo "OTA parser can recurse indefinitely on a non-boundary firmware byte." >&2
  exit 1
fi

timeout_branch="$(sed -n '/CLIENT_IDLE_TIMEOUT_MS/,/for (size_t bytesRead/p' "$implementation")"
if ! tr '\n' '\r' <<<"$timeout_branch" |
      grep -q 'failOta("Firmware upload timed out");\r *finishOtaRequest();' ||
   tr '\n' '\r' <<<"$timeout_branch" |
      grep -q 'failOta("Firmware upload timed out");\r *clearOtaInterlock();'; then
  echo "Connected OTA timeout does not send ota_failed before releasing the interlock." >&2
  exit 1
fi

if ! grep -q 'parseMultipartParameter' "$implementation" ||
   ! grep -q 'endsWithIgnoreCase' "$implementation" ||
   ! grep -q 'application/octet-stream' "$implementation" ||
   ! grep -q 'OtaTerminalCrLf' "$repo_dir/HttpApi.h" ||
   ! grep -q 'receivedBodyLength_ != expectedBodyLength_' "$implementation"; then
  echo "OTA multipart fields or terminal delimiter are not fully validated." >&2
  exit 1
fi

if ! grep -q 'const size_t headerWritten = client_\.write' "$implementation" ||
   ! grep -q 'headerWritten == static_cast<size_t>(headerLength)' "$implementation"; then
  echo "HTTP response writes do not guard against a partial header write." >&2
  exit 1
fi

completion="$(sed -n '/void HttpApi::finishOtaRequest()/,/void HttpApi::failOta/p' "$implementation")"
if ! grep -q 'bool sendResponse(int status, const char\* body, size_t bodyLength)' "$repo_dir/HttpApi.h" ||
   ! grep -q 'bool HttpApi::sendResponse(int status, const char\* body, size_t bodyLength)' "$implementation" ||
   ! tr '\n' '\r' <<<"$completion" |
      grep -q 'if (sendResponse(200, success, sizeof(success) - 1)) {\r *rebootScheduled_ = true;'; then
  echo "OTA success schedules reboot without confirmed complete response delivery." >&2
  exit 1
fi

echo "OTA parser progresses, timeout failures respond, and reboot requires full success delivery."

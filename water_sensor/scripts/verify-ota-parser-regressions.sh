#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
implementation="$repo_dir/HttpApi.cpp"

file_matcher="$(sed -n '/bool HttpApi::handleOtaFileByte/,/^}/p' "$implementation")"
if rg -q 'return handleOtaFileByte\(byte\)' <<<"$file_matcher"; then
  echo "OTA parser can recurse indefinitely on a non-boundary firmware byte." >&2
  exit 1
fi

timeout_branch="$(sed -n '/CLIENT_IDLE_TIMEOUT_MS/,/for (size_t bytesRead/p' "$implementation")"
if ! rg -U -q 'failOta\("Firmware upload timed out"\);\n\s*finishOtaRequest\(\);' <<<"$timeout_branch" ||
   rg -U -q 'failOta\("Firmware upload timed out"\);\n\s*clearOtaInterlock\(\);' <<<"$timeout_branch"; then
  echo "Connected OTA timeout does not send ota_failed before releasing the interlock." >&2
  exit 1
fi

if ! rg -q 'parseMultipartParameter' "$implementation" ||
   ! rg -q 'endsWithIgnoreCase' "$implementation" ||
   ! rg -q 'application/octet-stream' "$implementation" ||
   ! rg -q 'OtaTerminalCrLf' "$repo_dir/HttpApi.h" ||
   ! rg -q 'receivedBodyLength_ != expectedBodyLength_' "$implementation"; then
  echo "OTA multipart fields or terminal delimiter are not fully validated." >&2
  exit 1
fi

if ! rg -q 'const size_t headerWritten = client_\.write' "$implementation" ||
   ! rg -q 'headerWritten == static_cast<size_t>\(headerLength\)' "$implementation"; then
  echo "HTTP response writes do not guard against a partial header write." >&2
  exit 1
fi

completion="$(sed -n '/void HttpApi::finishOtaRequest()/,/void HttpApi::failOta/p' "$implementation")"
if ! rg -q 'bool sendResponse\(int status, const char\* body, size_t bodyLength\)' "$repo_dir/HttpApi.h" ||
   ! rg -q 'bool HttpApi::sendResponse\(int status, const char\* body, size_t bodyLength\)' "$implementation" ||
   ! rg -U -q 'if \(sendResponse\(200, success, sizeof\(success\) - 1\)\) \{\n\s*rebootScheduled_ = true;' <<<"$completion"; then
  echo "OTA success schedules reboot without confirmed complete response delivery." >&2
  exit 1
fi

echo "OTA parser progresses, timeout failures respond, and reboot requires full success delivery."

#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
webserver_parser="$repo_dir/.arduino/data/packages/esp32/hardware/esp32/3.3.11/libraries/WebServer/src/Parsing.cpp"

if ! rg -q 'readBytesWithTimeout\(client, _clientContentLength' "$webserver_parser"; then
  echo "Cannot establish the pinned WebServer plain-POST buffering behavior." >&2
  exit 2
fi

if rg -q 'WebServer server_' "$repo_dir/HttpApi.h"; then
  echo "Unsafe: WebServer buffers ordinary POST bodies before HttpApi can authenticate them." >&2
  exit 1
fi

if ! rg -q 'NetworkServer server_' "$repo_dir/HttpApi.h"; then
  echo "HttpApi does not declare the required incremental NetworkServer transport." >&2
  exit 1
fi

if ! rg -q 'MAX_BYTES_PER_HANDLE' "$repo_dir/HttpApi.cpp"; then
  echo "HttpApi has no explicit per-loop input-work bound." >&2
  exit 1
fi

echo "HTTP transport avoids WebServer pre-handler plain-body buffering."

#!/usr/bin/env bash
# Canary smoke test: backend unit/integration tests + web typecheck/build.
# No Docker and no Flutter required. Exit 0 = PASS.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[smoke] repo root: $ROOT"
fail=0

echo "==================== Backend tests ===================="
(
  cd "$ROOT/backend" || exit 1
  [ -d .venv ] || python3 -m venv .venv
  # shellcheck disable=SC1091
  . .venv/bin/activate
  pip install -e ".[dev]" -q 2>/dev/null || pip install -q \
    fastapi "uvicorn[standard]" "sqlalchemy[asyncio]" aiosqlite httpx \
    pydantic pydantic-settings pyjwt python-multipart pytest pytest-asyncio anyio
  python -m pytest -q
) || fail=1

echo "==================== Web build ========================"
(
  cd "$ROOT/web" || exit 1
  [ -d node_modules ] || npm install
  npm run build
) || fail=1

echo "======================================================="
if [ "$fail" -eq 0 ]; then
  echo "SMOKE: PASS"
else
  echo "SMOKE: FAIL"
fi
exit "$fail"

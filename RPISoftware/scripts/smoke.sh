#!/usr/bin/env bash
# Canary smoke test: backend unit/integration tests + web typecheck/build +
# static checks of the hub infra (scripts, simulators, compose file).
# No Docker daemon and no Flutter required. Exit 0 = PASS.
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

echo "==================== Hub infra (static) ==============="
(
  cd "$ROOT" || exit 1
  for script in scripts/*.sh; do bash -n "$script" || exit 1; done
  python3 -c 'import ast, sys; [ast.parse(open(p).read(), p) for p in sys.argv[1:]]' \
    simulator/hw_sim.py simulator/simulate.py || exit 1
  if docker compose version >/dev/null 2>&1; then
    # Dummy secrets: only the file's syntax and interpolation are checked.
    CANARY_MQTT_PASSWORD=smoke CANARY_JWT_SECRET=smoke \
      docker compose --profile sim config -q || exit 1
  else
    echo "(docker compose not installed: compose file not checked)"
  fi
  echo "infra OK"
) || fail=1

echo "======================================================="
if [ "$fail" -eq 0 ]; then
  echo "SMOKE: PASS"
else
  echo "SMOKE: FAIL"
fi
exit "$fail"

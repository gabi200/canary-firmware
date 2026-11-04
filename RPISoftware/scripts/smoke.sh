#!/usr/bin/env bash
# Canary smoke test: backend unit/integration tests + web typecheck/build +
# static checks of the hub infra (scripts, cluster images' scripts, simulators,
# compose file in one-Pi and three-Pi mode).
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
  for script in scripts/*.sh cluster/*/*.sh; do bash -n "$script" || exit 1; done
  python3 -c 'import ast, sys; [ast.parse(open(p).read(), p) for p in sys.argv[1:]]' \
    simulator/hw_sim.py simulator/simulate.py || exit 1
  if python3 -m pytest --version >/dev/null 2>&1; then
    python3 -m pytest -q -p no:cacheprovider cluster/announcer/test_announcer.py cluster/relay/test_relay.py || exit 1
  else
    echo "(pytest not installed for python3: announcer and relay tests not run)"
  fi
  if docker compose version >/dev/null 2>&1; then
    # Dummy secrets: only the file's syntax and interpolation are checked.
    CANARY_MQTT_PASSWORD=smoke CANARY_JWT_SECRET=smoke \
      docker compose --profile sim config -q || exit 1
    # Three Pis (profile "cluster"): a dummy cluster on documentation addresses, the variables
    # scripts/pi_setup.sh --cluster writes.
    CANARY_MQTT_PASSWORD=smoke CANARY_JWT_SECRET=smoke CANARY_CLUSTER_MODE=triple \
      CANARY_NODE_NAME=web CANARY_NODE_IP=192.0.2.12 CANARY_VIP=192.0.2.10 \
      CANARY_PROCESSING_IP=192.0.2.11 CANARY_WEB_IP=192.0.2.12 CANARY_AI_IP=192.0.2.13 \
      CANARY_PG_SUPERUSER_PASSWORD=smoke CANARY_PG_REPLICATION_PASSWORD=smoke \
      CANARY_DB_PASSWORD=smoke CANARY_VRRP_PASSWORD=smoke CANARY_MQTT_HOST=192.0.2.10 \
      docker compose --profile cluster config -q || exit 1
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

#!/bin/sh
# Canary three-Pi hub: start Patroni on this Pi (image cluster/patroni, compose service "postgres").
#
# docker-compose.yml maps this Pi's .env (written by scripts/pi_setup.sh) onto Patroni's own
# PATRONI_* variables. They are checked first: a half-written .env, or one copied from another Pi
# without re-running scripts/pi_setup.sh here, must stop with a message that says what to do
# instead of starting a second member under another Pi's name.
set -eu

die() {
  echo "canary-patroni: error: $*" >&2
  echo "canary-patroni: run scripts/pi_setup.sh on this Pi (RUNME.md section 3), then docker compose up -d" >&2
  exit 1
}

# <variable>:<where its value comes from in .env>
for pair in CANARY_NODE_NAME:CANARY_NODE_NAME CANARY_NODE_IP:CANARY_NODE_IP \
  PATRONI_SUPERUSER_PASSWORD:CANARY_PG_SUPERUSER_PASSWORD \
  PATRONI_REPLICATION_PASSWORD:CANARY_PG_REPLICATION_PASSWORD \
  PATRONI_RESTAPI_PASSWORD:CANARY_PG_SUPERUSER_PASSWORD \
  CANARY_DB_PASSWORD:CANARY_DB_PASSWORD; do
  eval "value=\${${pair%%:*}:-}"
  [ -n "$value" ] || die "${pair#*:} is not set in .env"
done
case "$CANARY_NODE_NAME" in
  processing | web | ai) ;;
  *) die "CANARY_NODE_NAME must be processing, web or ai, not '$CANARY_NODE_NAME'" ;;
esac
case "${PATRONI_ETCD3_HOSTS:-}" in
  "" | *"':"*) die "CANARY_PROCESSING_IP, CANARY_WEB_IP and CANARY_AI_IP must all be set in .env" ;;
  *"'$CANARY_NODE_IP:"*) ;;
  *) die "CANARY_NODE_IP $CANARY_NODE_IP is none of CANARY_PROCESSING_IP, CANARY_WEB_IP, CANARY_AI_IP" ;;
esac
# Binding to the address succeeds only when it belongs to this machine.
python3 -c 'import socket, sys; socket.socket().bind((sys.argv[1], 0))' "$CANARY_NODE_IP" 2>/dev/null ||
  die "CANARY_NODE_IP $CANARY_NODE_IP is not an address of this Pi (.env copied from another Pi without re-running scripts/pi_setup.sh here?)"

exec patroni /etc/patroni/patroni.yml

#!/usr/bin/env bash
# Update the hub's Pis from a shell, through this Pi's canary-updater (the same thing the
# dashboard's Administration -> Hub -> Software does). RUNME.md, "Updating the hub".
#
#   scripts/hub_update.sh status            this Pi's version and update state
#   scripts/hub_update.sh fetch             check GitHub now
#   scripts/hub_update.sh all               update every Pi to origin/main, one at a time
#   scripts/hub_update.sh processing|web|ai update only that Pi (three Pis); "hub" on one Pi
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"

die() {
  echo "hub_update: $*" >&2
  exit 1
}
env_value() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}
json() { # json <expression on d> : read JSON from stdin
  python3 -c "import json,sys; d=json.load(sys.stdin); v=$1; print('' if v is None else v)"
}

[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE: run scripts/pi_setup.sh first"
KEY="$(env_value CANARY_UPDATER_KEY)"
[[ -n "$KEY" ]] || die "CANARY_UPDATER_KEY is missing in .env: run scripts/pi_setup.sh"
PORT="$(env_value CANARY_UPDATER_PORT)"
PORT="${PORT:-8010}"
if [[ "$(env_value CANARY_CLUSTER_MODE)" == triple ]]; then
  triple=1
  HERE="$(env_value CANARY_NODE_IP)"
else
  triple=0
  HERE=127.0.0.1
fi

api() { # api METHOD HOST PATH [JSON] -> prints the body, then a line with the HTTP status
  local args=(-s -m 60 -X "$1" -H "X-Canary-Updater-Key: $KEY" -w '\n%{http_code}')
  [[ $# -lt 4 ]] || args+=(-H 'Content-Type: application/json' -d "$4")
  curl "${args[@]}" "http://$2:$PORT$3" || echo -e "\n000"
}
call() { # call METHOD HOST PATH [JSON] -> body on stdout; dies on a connection error
  local out code
  out="$(api "$@")"
  code="${out##*$'\n'}"
  [[ "$code" != 000 ]] || die "the updater on $2 does not answer (is canary-updater running? systemctl status canary-updater)"
  printf '%s' "${out%$'\n'*}"
  [[ "$code" == 2* ]] || {
    echo >&2
    die "refused ($code): $(printf '%s' "${out%$'\n'*}" | json 'd.get("error")' 2>/dev/null || true)"
  }
}
show() {
  json '"%s  %s  %s  state=%s  step=%s  behind=%s%s" % (d["node"], (d.get("commit") or {}).get("sha","?")[:7], (d.get("commit") or {}).get("subject",""), d["state"], d.get("step"), d.get("behind"), ("  error=" + d["error"]) if d.get("error") else "")'
}
host_of() {
  case "$1" in
    hub) [[ $triple -eq 0 ]] || die "this is a three-Pi hub: name processing, web or ai"; echo 127.0.0.1 ;;
    processing | web | ai)
      [[ $triple -eq 1 ]] || die "this is a one-Pi hub: use 'hub'"
      env_value "CANARY_$(tr '[:lower:]' '[:upper:]' <<<"$1")_IP"
      ;;
    *) die "unknown Pi '$1' (processing, web, ai or hub)" ;;
  esac
}
wait_done() { # wait_done HOST SHA [rollout]
  local st state
  while true; do
    sleep 5
    st="$(api GET "$1" /status)"
    [[ "${st##*$'\n'}" == 200 ]] || { echo "   (updater on $1 not answering, waiting)"; continue; }
    st="${st%$'\n'*}"
    if [[ "${3:-}" == rollout ]]; then
      state="$(json '(d.get("rollout") or {}).get("outcome")' <<<"$st")"
      echo "   $(json '" ".join("%s:%s" % kv for kv in (d.get("rollout") or {}).get("results", {}).items())' <<<"$st")"
      [[ "$state" == running ]] && continue
      echo "rollout $state $(json '(d.get("rollout") or {}).get("reason") or ""' <<<"$st")"
      [[ "$state" == done ]]
      return
    fi
    state="$(json 'd["state"]' <<<"$st")"
    echo "   $(show <<<"$st")"
    [[ "$state" == updating || "$state" == rolling_back ]] && continue
    [[ "$state" == idle && "$(json '(d.get("commit") or {}).get("sha")' <<<"$st")" == "$2" ]]
    return
  done
}

case "${1:-status}" in
  status) call GET "$HERE" /status | show ;;
  fetch) call POST "$HERE" /fetch | show ;;
  all | processing | web | ai | hub)
    [[ "$1" == all ]] || host="$(host_of "$1")"
    sha="$(call GET "$HERE" /incoming | json '(d.get("head") or {}).get("sha")')"
    [[ -n "$sha" ]] || die "origin/main unknown: run 'scripts/hub_update.sh fetch' first"
    echo "Updating ${1} to ${sha:0:7} (origin/main)"
    if [[ "$1" == all ]]; then
      call POST "$HERE" /rollout "{\"commit\": \"$sha\"}" >/dev/null
      wait_done "$HERE" "$sha" rollout
    else
      call POST "$host" /update "{\"commit\": \"$sha\"}" >/dev/null
      wait_done "$host" "$sha"
    fi
    ;;
  -h | --help) sed -n '2,9p' "$0" ;;
  *) die "usage: scripts/hub_update.sh [status|fetch|all|processing|web|ai|hub]" ;;
esac

#!/usr/bin/env bash
# End-to-end test of the relay against real brokers, in a private Docker network with no published
# ports, so it can run beside a live hub. Needs the images eclipse-mosquitto:2 and canary-backend
# (nothing is pulled: a Pi on the hotspot has no route to a registry).
#
#   cluster/relay/e2e_relay.sh
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=relay-e2e
VIP=relay-e2e-vip
LOCAL=relay-e2e-local
RELAY=relay-e2e-relay
LOOP=relay-e2e-loop
IDLE=relay-e2e-idle
failures=0

cleanup() {
  docker rm -f "$VIP" "$LOCAL" "$RELAY" "$LOOP" "$IDLE" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null || exit 1

broker() {
  docker run -d --name "$1" --network "$NET" --entrypoint sh eclipse-mosquitto:2 -c '
    printf "listener 1883\nallow_anonymous true\npersistence true\npersistence_location /mosquitto/data/\n" >/tmp/m.conf
    exec mosquitto -c /tmp/m.conf' >/dev/null || exit 1
}
relay() { # name, then docker run options
  local name=$1
  shift
  docker run -d --name "$name" -v "$DIR:/relay:ro" -e CANARY_MQTT_PASSWORD=e2e -e "CANARY_NODE_NAME=$name" \
    "$@" canary-backend python -u /relay/relay.py >/dev/null || exit 1
}
pub() { # broker, then mosquitto_pub options
  local broker=$1
  shift
  docker exec "$broker" mosquitto_pub -h localhost -q 1 "$@"
}
listen() { # broker, log name: what a client that stays subscribed sees, as "<retain flag> <topic> <payload>"
  docker exec -d "$1" sh -c "exec mosquitto_sub -h localhost -q 1 -t '#' -F '%r %t %p' >/tmp/$2.log 2>&1"
  sleep 1
}
seen() { # broker, log name, exact line: how many times it was delivered
  docker exec "$1" cat "/tmp/$2.log" | tr -d '\000' | grep -cxF -- "$3"
}
stored() { # broker, topic: the retained payload, empty when there is none
  docker exec "$1" sh -c "timeout 2 mosquitto_sub -h localhost -t '$2' --retained-only -F '%p' 2>/dev/null"
}
check() { # description, want, got
  if [ "$2" = "$3" ]; then
    echo "ok    $1"
  else
    echo "FAIL  $1: want '$2', got '$3'"
    failures=$((failures + 1))
  fi
}
wait_for_log() { # container, text
  local i
  for i in $(seq 1 40); do
    docker logs "$1" 2>&1 | grep -qF -- "$2" && return 0
    sleep 0.5
  done
  echo "timed out waiting for '$2' in $1:"
  docker logs "$1" 2>&1 | tail -20
  return 1
}

broker "$VIP"
broker "$LOCAL"
sleep 2

# What is on the brokers before the relay starts: the documents a dead sensor left behind.
pub "$LOCAL" -r -t stale_water/status -m stale-wet
pub "$LOCAL" -r -t stale_water/availability -m offline
pub "$VIP" -r -t stale_vip/status -m stale-on-vip
pub "$VIP" -r -t stale_valve/valve/set -m OPEN
pub "$VIP" -r -t shared/status -m newer-on-vip

listen "$VIP" hub
listen "$LOCAL" sensor

relay "$RELAY" --network "$NET" -e "CANARY_VIP=$VIP" -e "CANARY_RELAY_LOCAL_HOST=$LOCAL"
wait_for_log "$RELAY" "relaying between" || exit 1
sleep 2

echo "--- starting the relay replays nothing"
check "the hub gets no stale status" 0 "$(seen "$VIP" hub '0 stale_water/status stale-wet')"
check "the hub gets no stale availability" 0 "$(seen "$VIP" hub '0 stale_water/availability offline')"
check "a stale copy does not overwrite the VIP's retained one" "stale-on-vip" "$(stored "$VIP" stale_vip/status)"
check "a stale status is not copied up" "" "$(stored "$VIP" stale_water/status)"
check "a retained command does not reach the sensor" 0 "$(seen "$LOCAL" sensor '0 stale_valve/valve/set OPEN')"
check "the VIP's stale status is not copied down" 0 "$(seen "$LOCAL" sensor '0 stale_vip/status stale-on-vip')"

echo "--- live messages cross exactly once"
pub "$LOCAL" -r -t canary/status -m live-1
pub "$LOCAL" -r -t canary/availability -m online
pub "$LOCAL" -t canary/command/result -m accepted
pub "$VIP" -t canary/buzzer/set -m SILENCE
sleep 2
check "a status reaches the hub once" 1 "$(seen "$VIP" hub '0 canary/status live-1')"
check "availability reaches the hub once" 1 "$(seen "$VIP" hub '0 canary/availability online')"
check "a command result reaches the hub once" 1 "$(seen "$VIP" hub '0 canary/command/result accepted')"
check "a command reaches the sensor once" 1 "$(seen "$LOCAL" sensor '0 canary/buzzer/set SILENCE')"
check "a status does not bounce back to the sensor's broker" 1 "$(seen "$LOCAL" sensor '0 canary/status live-1')"
check "the VIP keeps the current status retained" "live-1" "$(stored "$VIP" canary/status)"
check "a command result is not stored" "" "$(stored "$VIP" canary/command/result)"
check "a command is not stored on the sensor's broker" "" "$(stored "$LOCAL" canary/buzzer/set)"

echo "--- a dropped link replays nothing and recovers"
docker stop -t 2 "$VIP" >/dev/null
pub "$LOCAL" -r -t canary/status -m published-while-down
docker start "$VIP" >/dev/null
sleep 1
listen "$VIP" hub2
sleep 8
check "the message from the outage is not delivered late" 0 "$(seen "$VIP" hub2 '0 canary/status published-while-down')"
pub "$LOCAL" -r -t canary/status -m live-after-outage
sleep 2
check "the next live status arrives" 1 "$(seen "$VIP" hub2 '0 canary/status live-after-outage')"

echo "--- a Mosquitto restart of the sensor's broker replays nothing"
docker stop -t 2 "$LOCAL" >/dev/null
docker start "$LOCAL" >/dev/null
sleep 8
check "the stale status still stays out" 0 "$(seen "$VIP" hub2 '0 stale_water/status stale-wet')"

echo "--- two relays that disagree about the VIP cannot loop"
# This one believes it is off the VIP while both its links lead to the same broker.
relay "$LOOP" --network "$NET" -e "CANARY_VIP=$VIP" -e "CANARY_RELAY_LOCAL_HOST=$VIP"
wait_for_log "$LOOP" "relaying between" || exit 1
sleep 1
pub "$VIP" -r -t looptest/status -m once
sleep 4
check "a message is copied at most once (original + 1)" 2 "$(seen "$VIP" hub2 '0 looptest/status once')"
docker rm -f "$LOOP" >/dev/null

echo "--- the Pi holding the VIP stays idle"
vip_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$VIP")"
relay "$IDLE" --network "container:$VIP" -e "CANARY_VIP=$vip_ip"
wait_for_log "$IDLE" "idle" || exit 1
pub "$VIP" -r -t idletest/status -m once
sleep 2
check "it does not copy messages" 1 "$(seen "$VIP" hub2 '0 idletest/status once')"

echo
if [ "$failures" -eq 0 ]; then
  echo "all relay checks passed"
else
  echo "$failures relay check(s) FAILED"
  exit 1
fi

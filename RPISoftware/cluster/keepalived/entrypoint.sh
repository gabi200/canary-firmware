#!/bin/sh
# Canary three-Pi hub: keepalived for this Pi (image cluster/keepalived, compose service
# "keepalived"; RUNME.md section 3).
#
# Renders /etc/keepalived/keepalived.conf from this Pi's .env (scripts/pi_setup.sh): unicast VRRP
# between the three Pis' addresses, the floating IP (CANARY_VIP) on the interface that holds
# CANARY_NODE_IP with that interface's prefix length, priority web 150 > processing 100 > ai 50.
# Only a Pi whose front door works (canary-front-door-check) may hold the VIP; a better Pi takes
# it back 30 s after it is up again (preempt_delay). canary-vrrp-notify keeps the state word in
# /run/canary/vrrp_state for the backend.
set -eu

STATE_FILE=/run/canary/vrrp_state

die() {
  echo "canary-keepalived: error: $*" >&2
  echo "canary-keepalived: run scripts/pi_setup.sh on this Pi (RUNME.md section 3), then docker compose up -d" >&2
  exit 1
}

# Not the VIP holder until keepalived says otherwise (a killed container leaves MASTER behind).
mkdir -p /run/canary
echo STOP >"$STATE_FILE"

for var in CANARY_NODE_NAME CANARY_NODE_IP CANARY_PROCESSING_IP CANARY_WEB_IP CANARY_AI_IP \
  CANARY_VIP CANARY_VRRP_PASSWORD; do
  eval "value=\${$var:-}"
  [ -n "$value" ] || die "$var is not set in .env"
done
case "$CANARY_NODE_NAME" in
  processing) priority=100 own_ip=$CANARY_PROCESSING_IP ;;
  web) priority=150 own_ip=$CANARY_WEB_IP ;;
  ai) priority=50 own_ip=$CANARY_AI_IP ;;
  *) die "CANARY_NODE_NAME must be processing, web or ai, not '$CANARY_NODE_NAME'" ;;
esac
[ "$own_ip" = "$CANARY_NODE_IP" ] ||
  die "CANARY_NODE_IP $CANARY_NODE_IP is not the $CANARY_NODE_NAME Pi's address ($own_ip)"
case "$CANARY_VRRP_PASSWORD" in
  *[!A-Za-z0-9]*) die "CANARY_VRRP_PASSWORD may only contain letters and digits" ;;
esac
http_port=${CANARY_HTTP_PORT:-80}
case "$http_port" in
  "" | *[!0-9]*) die "CANARY_HTTP_PORT must be a port number, not '$http_port'" ;;
esac

# The interface holding this Pi's address, and its prefix length. At boot the address can come up
# a little after Docker starts the container, so wait for it briefly.
tries=0
while :; do
  # shellcheck disable=SC2046 # two words on purpose: interface and prefix length
  set -- $(ip -4 -o addr show | awk -v ip="$CANARY_NODE_IP" \
    '{ split($4, a, "/"); if (a[1] == ip) { print $2, a[2]; exit } }')
  [ $# -eq 2 ] && break
  tries=$((tries + 1))
  [ "$tries" -lt 20 ] || die "CANARY_NODE_IP $CANARY_NODE_IP is not an address of this Pi" \
    "(was .env copied from another Pi without re-running scripts/pi_setup.sh here?)"
  sleep 1
done
iface=$1
prefix=$2

# A VIP left behind by a keepalived that was killed (no clean shutdown) would answer ARP next to
# the real holder's.
for stale in $(ip -4 -o addr show dev "$iface" | awk -v ip="$CANARY_VIP" \
  '{ split($4, a, "/"); if (a[1] == ip) print $4 }'); do
  ip addr del "$stale" dev "$iface" && echo "canary-keepalived: removed a stale $stale from $iface"
done

peers=""
for ip in "$CANARY_PROCESSING_IP" "$CANARY_WEB_IP" "$CANARY_AI_IP"; do
  [ "$ip" = "$CANARY_NODE_IP" ] || peers="$peers        $ip
"
done

umask 077 # the file holds the VRRP password
mkdir -p /etc/keepalived
cat >/etc/keepalived/keepalived.conf <<EOF
# Rendered by canary-keepalived from .env when the container starts: change .env, not this file.
global_defs {
    router_id canary-$CANARY_NODE_NAME
    script_user root
    enable_script_security
}

vrrp_script front_door {
    script "/usr/local/bin/canary-front-door-check $http_port"
    interval 2
    timeout 5
    fall 3
    rise 2
    init_fail
}

vrrp_instance canary {
    state BACKUP
    interface $iface
    virtual_router_id 61
    priority $priority
    advert_int 1
    preempt_delay 30
    unicast_src_ip $CANARY_NODE_IP
    unicast_peer {
$peers    }
    authentication {
        auth_type PASS
        auth_pass $CANARY_VRRP_PASSWORD
    }
    virtual_ipaddress {
        $CANARY_VIP/$prefix dev $iface
    }
    track_script {
        front_door
    }
    notify /usr/local/bin/canary-vrrp-notify
}
EOF
echo "canary-keepalived: $CANARY_NODE_NAME (priority $priority) on $iface, VIP $CANARY_VIP/$prefix"

# keepalived keeps pid files in /run, which survives a container restart: a stale one whose PID
# is alive again in the new container makes it refuse to start.
rm -f /run/keepalived.pid /run/vrrp.pid /run/checkers.pid /run/keepalived/*.pid 2>/dev/null || true
exec keepalived --dont-fork --log-console --vrrp --use-file /etc/keepalived/keepalived.conf

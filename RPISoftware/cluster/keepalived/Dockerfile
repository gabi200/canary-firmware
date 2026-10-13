# Canary three-Pi hub: keepalived keeps the floating IP (CANARY_VIP) on a Pi whose front door
# works (RUNME.md section 3). Built by docker compose (service "keepalived", profile "cluster");
# runs in the host's network namespace with NET_ADMIN, NET_RAW and NET_BROADCAST.
FROM alpine:3.24.2

# netcat-openbsd: `nc -z` for the broker check (busybox wget does the HTTP one).
RUN apk add --no-cache keepalived netcat-openbsd

COPY entrypoint.sh /usr/local/bin/canary-keepalived
COPY front_door_check.sh /usr/local/bin/canary-front-door-check
COPY notify.sh /usr/local/bin/canary-vrrp-notify

# keepalived itself becomes PID 1 (exec): on SIGTERM it drops the VIP and tells the other Pis.
ENTRYPOINT ["/usr/local/bin/canary-keepalived"]

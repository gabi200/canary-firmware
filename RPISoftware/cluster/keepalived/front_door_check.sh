#!/bin/sh
# keepalived track script (cluster/keepalived/entrypoint.sh): may this Pi be the front door?
# Yes while the dashboard answers through nginx and the backend (/health) and the MQTT broker
# accepts connections. $1: the dashboard's port (CANARY_HTTP_PORT).
wget -q -T 2 -O /dev/null "http://127.0.0.1:${1:-80}/health" && nc -z -w 2 127.0.0.1 1883

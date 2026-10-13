#!/bin/sh
# keepalived notify script (cluster/keepalived/entrypoint.sh). Arguments: INSTANCE, its name, the
# new state (MASTER | BACKUP | FAULT | STOP), the priority. Writes the state word to
# /run/canary/vrrp_state (volume cluster_state, read-only in the backend): MASTER = this Pi holds
# the floating IP. Replaced atomically, so a reader never sees half a word.
set -eu
umask 022
printf '%s\n' "$3" >/run/canary/vrrp_state.tmp
mv -f /run/canary/vrrp_state.tmp /run/canary/vrrp_state

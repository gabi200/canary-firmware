#!/usr/bin/env bash
# Canary hub setup. Run it once on the Raspberry Pi (or a laptop with Docker),
# and again whenever you add a sensor. Safe to re-run: it never changes an
# existing secret unless asked to.
#
#   scripts/pi_setup.sh                              # secrets + broker user "hub"
#   scripts/pi_setup.sh air-kitchen water-kitchen    # ... plus one MQTT user per sensor
#   scripts/pi_setup.sh --rotate air-kitchen         # new password for an existing sensor
#   scripts/pi_setup.sh --cluster 192.168.1.10 192.168.1.11 192.168.1.12 192.168.1.13
#                                 # three Pis: floating IP, then the processing, web and ai Pis
#
# It:
#   1. creates RPISoftware/.env (mode 600) with a random CANARY_JWT_SECRET,
#      CANARY_MQTT_PASSWORD (the backend's broker password), CANARY_CARE_KEY
#      (encrypts care profiles: health data) and CANARY_ESCALATION_SECRET (signs
#      the ARC / 112 escalation webhook) when missing;
#   2. writes mosquitto/config/passwd with user "hub" and every sensor user named
#      on the command line (new sensors get a random password, existing ones keep
#      theirs unless --rotate). mosquitto_passwd runs in a throwaway
#      eclipse-mosquitto:2 container and gets the passwords on stdin, never as
#      command-line arguments, so nothing but Docker is needed on the Pi;
#   3. makes that file readable by the broker only (uid 1883, mode 600) and
#      reloads the broker if it is running;
#   4. prints what to type into each ESP32's setup portal, and the hub URLs.
#
# Three Pis (RUNME.md section 3): --cluster, run on ONE Pi, also writes the settings the three
# share to .env (addresses, floating IP, cluster and database secrets, the database URL through
# pgproxy, and the broker host and public URL). On every run with CANARY_CLUSTER_MODE=triple in
# .env, it matches this machine's IPv4 addresses against the three Pis' and records
# CANARY_NODE_NAME / CANARY_NODE_IP. .env and mosquitto/config/passwd are then copied to the
# other two Pis, where this script runs once more.
#
# .env and mosquitto/config/passwd are gitignored: never commit them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
CONF_DIR="$ROOT/mosquitto/config"
MOSQUITTO_IMAGE="eclipse-mosquitto:2"
HUB_USER="hub"

usage() {
  cat <<'EOF'
usage: scripts/pi_setup.sh [--rotate] [sensor-user ...]
       scripts/pi_setup.sh --cluster <VIP> <PROCESSING_IP> <WEB_IP> <AI_IP> [sensor-user ...]

  sensor-user   MQTT user for one ESP32 sensor, e.g. air-kitchen or water-kitchen
                (1-32 letters, digits, '-' or '_'). Use the same text as the
                device's "MQTT base topic": every device needs a unique one.
  --rotate      issue new passwords for the listed sensors even if they exist.
  --cluster     three Pis (RUNME.md section 3): a free LAN address for the floating
                IP (the sensors' MQTT host and the dashboard / app address), then the
                processing, web and ai Pis' addresses. Run it on one Pi only, copy .env
                and mosquitto/config/passwd to the other two, run this script there.

Environment: CANARY_HUB_HOST=<ip-or-name> overrides the detected LAN address
that is printed for the sensors' "MQTT host" field. CANARY_NODE_NAME=processing,
web or ai names this Pi's role in a three-Pi hub instead of matching its addresses.
EOF
}

die() {
  echo "pi_setup: error: $*" >&2
  exit 1
}

note() {
  echo "pi_setup: $*"
}

# N random bytes as hex (coreutils od: present on Raspberry Pi OS and macOS).
rand_hex() {
  od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
}

# A Fernet key: 32 random bytes, url-safe base64 (44 characters).
rand_fernet_key() {
  head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_'
}

# Last NAME=value in .env, without surrounding quotes or a trailing CR.
env_value() {
  local value
  value="$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -n 1 || true)"
  value="${value#*=}"
  value="${value%$'\r'}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

# Run a /bin/sh snippet in a throwaway Mosquitto container with the config dir
# mounted read-write. No network; the image entrypoint is bypassed.
in_mosquitto() {
  docker run --rm -i --network none --entrypoint /bin/sh \
    -v "$CONF_DIR:/mosquitto/config" "$MOSQUITTO_IMAGE" -c "$1"
}

# First IPv4 address of the interface holding the default route.
lan_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null |
      awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')" || true
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
  fi
  if [[ -z "$ip" ]] && command -v ipconfig >/dev/null 2>&1; then # macOS
    ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)" || true
  fi
  printf '%s' "${ip:-<pi-ip>}"
}

# Every IPv4 address of this machine, one per line.
local_ipv4s() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4 }'
  elif command -v ifconfig >/dev/null 2>&1; then # macOS
    ifconfig 2>/dev/null | awk '$1 == "inet" { print $2 }'
  fi
}

# A dotted-quad IPv4 address without leading zeros; not 0.x, loopback or multicast.
is_ipv4() {
  local octets o
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$1"
  for o in "${octets[@]}"; do
    [[ "$o" == 0 || "$o" != 0* ]] && ((o <= 255)) || return 1
  done
  ((octets[0] != 0 && octets[0] != 127 && octets[0] < 224))
}

# NAME=value in .env: replaces the existing line, or appends one.
set_env() {
  local tmp
  if grep -q "^$1=" "$ENV_FILE"; then
    tmp="$(mktemp "$ENV_FILE.XXXXXX")"
    NAME="$1" VALUE="$2" awk 'index($0, ENVIRON["NAME"] "=") == 1 {
        if (!done) print ENVIRON["NAME"] "=" ENVIRON["VALUE"]
        done = 1
        next
      }
      { print }' "$ENV_FILE" >"$tmp"
    mv -f "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE"
  fi
}

# Drops the NAME=... line from .env.
del_env() {
  local tmp
  grep -q "^$1=" "$ENV_FILE" || return 0
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  grep -v "^$1=" "$ENV_FILE" >"$tmp" || true
  mv -f "$tmp" "$ENV_FILE"
}

# Appends NAME=<random> to .env unless NAME is there already: secrets are never replaced.
add_secret() {
  if ! grep -q "^$1=" "$ENV_FILE"; then
    printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE"
    note "generated $1"
  fi
}

# Three Pis: a Pi's address as recorded in .env.
node_ip() {
  case "$1" in
    processing) env_value CANARY_PROCESSING_IP ;;
    web) env_value CANARY_WEB_IP ;;
    ai) env_value CANARY_AI_IP ;;
  esac
}

# ---------------------------------------------------------------- arguments
rotate=0
sensors=()
cluster_ips=() # --cluster: VIP, processing, web, ai
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --rotate) rotate=1 ;;
    --cluster)
      [[ $# -ge 5 ]] || die "--cluster needs four addresses: <VIP> <PROCESSING_IP> <WEB_IP> <AI_IP>"
      cluster_ips=("$2" "$3" "$4" "$5")
      shift 4
      ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *)
      [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] ||
        die "invalid sensor name '$1': use 1-32 letters, digits, '-' or '_' (it becomes the MQTT user)"
      [[ "$1" != "$HUB_USER" ]] || die "'$HUB_USER' is reserved for the backend"
      case " ${sensors[*]-} " in
        *" $1 "*) ;; # listed twice
        *) sensors+=("$1") ;;
      esac
      ;;
  esac
  shift
done
if [[ $rotate -eq 1 && ${#sensors[@]} -eq 0 ]]; then
  die "--rotate needs the sensor names to rotate"
fi
if [[ ${#cluster_ips[@]} -gt 0 ]]; then
  for ip in "${cluster_ips[@]}"; do
    is_ipv4 "$ip" || die "--cluster: '$ip' is not a usable IPv4 address (e.g. 192.168.1.10)"
  done
  [[ "$(printf '%s\n' "${cluster_ips[@]}" | sort -u | wc -l | tr -d ' ')" -eq 4 ]] ||
    die "--cluster: the floating IP and the three Pis need four different addresses"
fi

# ---------------------------------------------------------------- prerequisites
command -v docker >/dev/null 2>&1 ||
  die "Docker is not installed. On Raspberry Pi OS: curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker \"\$USER\", then log out and back in (see RUNME.md)."
docker info >/dev/null 2>&1 ||
  die "cannot reach the Docker daemon. Is it running, and is your user in the 'docker' group? (sudo usermod -aG docker \"\$USER\", then log out and back in)"
docker compose version >/dev/null 2>&1 ||
  die "the Docker Compose plugin is missing (sudo apt-get install docker-compose-plugin)."
case "$(uname -m)" in
  aarch64 | arm64 | x86_64 | amd64) ;;
  *) echo "pi_setup: warning: $(uname -m) detected; the hub is built for 64-bit Raspberry Pi OS (aarch64)." >&2 ;;
esac
[[ -f "$CONF_DIR/mosquitto.conf" ]] || die "missing $CONF_DIR/mosquitto.conf (run from a full checkout)"

# ---------------------------------------------------------------- 1. .env
umask 077
if [[ ! -f "$ENV_FILE" ]]; then
  cat >"$ENV_FILE" <<'EOF'
# Canary hub settings for docker compose, created by scripts/pi_setup.sh.
# Contains secrets: keep it mode 600 and never commit it (it is gitignored).
# Other backend settings (CANARY_*, docs/HARDWARE.md section 6) can be added
# below; apply them with `docker compose up -d`.
EOF
  note "created $ENV_FILE"
fi
if [[ -s "$ENV_FILE" && -n "$(tail -c 1 "$ENV_FILE")" ]]; then
  echo >>"$ENV_FILE" # file did not end with a newline
fi
if ! grep -q '^CANARY_JWT_SECRET=' "$ENV_FILE"; then
  printf 'CANARY_JWT_SECRET=%s\n' "$(rand_hex 32)" >>"$ENV_FILE"
  note "generated CANARY_JWT_SECRET"
fi
if ! grep -q '^CANARY_CARE_KEY=' "$ENV_FILE"; then
  # Encrypts care profiles (health data) at rest. Changing or losing it makes the stored
  # profiles unreadable, so it is never rotated here.
  printf 'CANARY_CARE_KEY=%s\n' "$(rand_fernet_key)" >>"$ENV_FILE"
  note "generated CANARY_CARE_KEY"
fi
if ! grep -q '^CANARY_ESCALATION_SECRET=' "$ENV_FILE"; then
  # HMAC key of the escalation webhook; give the same value to the ARC / 112 partner.
  printf 'CANARY_ESCALATION_SECRET=%s\n' "$(rand_hex 32)" >>"$ENV_FILE"
  note "generated CANARY_ESCALATION_SECRET"
fi
if ! grep -q '^CANARY_MQTT_PASSWORD=' "$ENV_FILE"; then
  printf 'CANARY_MQTT_PASSWORD=%s\n' "$(rand_hex 16)" >>"$ENV_FILE"
  note "generated CANARY_MQTT_PASSWORD (broker user '$HUB_USER')"
fi
# Key of canary-updater (cluster/canary-updater.service), the host-side helper that updates the
# hub from the dashboard. The same on all three Pis: it travels with the copied .env.
add_secret CANARY_UPDATER_KEY "$(rand_hex 32)"
# The "announcer" service publishes canary-hub.local only where CANARY_ANNOUNCE=1: on a Raspberry
# Pi by default, never on a laptop running the stack for development (it would take the name from
# the real hub on the same Wi-Fi). Set it in .env to override; it is never changed once present.
if ! grep -q '^CANARY_ANNOUNCE=' "$ENV_FILE"; then
  if tr -d '\0' </proc/device-tree/model 2>/dev/null | grep -q 'Raspberry Pi'; then
    printf 'CANARY_ANNOUNCE=1\n' >>"$ENV_FILE"
    note "CANARY_ANNOUNCE=1: this Pi announces the hub as canary-hub.local"
  else
    printf 'CANARY_ANNOUNCE=0\n' >>"$ENV_FILE"
    note "CANARY_ANNOUNCE=0: not a Raspberry Pi, the hub name is not announced from here"
  fi
fi

# ---------------------------------------------------------------- 1b. three Pis
# --cluster: what the three Pis share. Secrets are generated once and kept; the addresses and
# the settings derived from them follow the latest --cluster.
if [[ ${#cluster_ips[@]} -gt 0 ]]; then
  if ! grep -q '^CANARY_CLUSTER_MODE=' "$ENV_FILE"; then
    printf '%s\n' "# Three Pis (scripts/pi_setup.sh --cluster, RUNME.md section 3): the same on all three," \
      "# except CANARY_NODE_NAME, CANARY_NODE_IP and (AI Pi only) CANARY_LLM_URL, which" \
      "# scripts/pi_setup.sh sets on each Pi." >>"$ENV_FILE"
  fi
  set_env CANARY_CLUSTER_MODE triple
  profiles="$(env_value COMPOSE_PROFILES)" # docker compose reads it: starts the cluster services
  case ",$profiles," in
    *,cluster,*) ;;
    ,,) set_env COMPOSE_PROFILES cluster ;;
    *) set_env COMPOSE_PROFILES "$profiles,cluster" ;;
  esac
  set_env CANARY_VIP "${cluster_ips[0]}"
  set_env CANARY_PROCESSING_IP "${cluster_ips[1]}"
  set_env CANARY_WEB_IP "${cluster_ips[2]}"
  set_env CANARY_AI_IP "${cluster_ips[3]}"
  add_secret CANARY_CLUSTER_SECRET "$(rand_hex 32)" # node-to-node API key
  add_secret CANARY_PG_SUPERUSER_PASSWORD "$(rand_hex 24)"
  add_secret CANARY_PG_REPLICATION_PASSWORD "$(rand_hex 24)"
  add_secret CANARY_DB_PASSWORD "$(rand_hex 24)" # the backend's database role "canary"
  add_secret CANARY_VRRP_PASSWORD "$(rand_hex 4)" # keepalived uses 8 characters at most
  db_password="$(env_value CANARY_DB_PASSWORD)"
  [[ "$db_password" =~ ^[A-Za-z0-9]+$ ]] ||
    die "CANARY_DB_PASSWORD in $ENV_FILE may only contain letters and digits (it goes into CANARY_DATABASE_URL)"
  # pgproxy (HAProxy, one per Pi) forwards to whichever Pi holds the Postgres primary.
  set_env CANARY_DATABASE_URL "postgresql+asyncpg://canary:$db_password@pgproxy:5432/canary"
  set_env CANARY_MQTT_HOST "${cluster_ips[0]}" # the broker of whichever Pi holds the floating IP
  # Fallback base of shareable links (household invites); the backend prefers the address the
  # request came in on. canary-hub.local is announced by the "announcer" service.
  public_url="http://canary-hub.local"
  http_port="$(env_value CANARY_HTTP_PORT)"
  if [[ -n "$http_port" && "$http_port" != 80 ]]; then public_url+=":$http_port"; fi
  set_env CANARY_PUBLIC_URL "$public_url"
  note "three-Pi settings written: floating IP ${cluster_ips[0]}, processing ${cluster_ips[1]}, web ${cluster_ips[2]}, ai ${cluster_ips[3]}"
fi

# Every run on a three-Pi hub: which of the three is this machine? (A copied .env still names
# the Pi it was copied from.)
cluster=0
if [[ "$(env_value CANARY_CLUSTER_MODE)" == triple ]]; then
  cluster=1
  for var in CANARY_VIP CANARY_PROCESSING_IP CANARY_WEB_IP CANARY_AI_IP; do
    [[ -n "$(env_value "$var")" ]] ||
      die "$var is missing in $ENV_FILE: run scripts/pi_setup.sh --cluster <VIP> <PROCESSING_IP> <WEB_IP> <AI_IP> on one Pi, then copy its .env here"
  done
  mine="$(local_ipv4s)"
  node="${CANARY_NODE_NAME:-}"
  if [[ -n "$node" ]]; then
    case "$node" in
      processing | web | ai) ;;
      *) die "CANARY_NODE_NAME must be processing, web or ai, not '$node'" ;;
    esac
    grep -qxF -- "$(node_ip "$node")" <<<"$mine" ||
      echo "pi_setup: warning: $(node_ip "$node") ($node) is not an address of this machine: keepalived and Patroni will refuse to start here" >&2
  else
    matches=()
    for name in processing web ai; do
      if grep -qxF -- "$(node_ip "$name")" <<<"$mine"; then matches+=("$name"); fi
    done
    have="${mine//$'\n'/, }"
    case ${#matches[@]} in
      1) node="${matches[0]}" ;;
      0) die "this machine (${have:-no IPv4 address found}) has none of the three Pis' addresses in .env: processing $(node_ip processing), web $(node_ip web), ai $(node_ip ai). Give this Pi its reserved address, or name its role: CANARY_NODE_NAME=processing|web|ai scripts/pi_setup.sh" ;;
      *) die "this machine has the addresses of several Pis (${matches[*]}): name its role with CANARY_NODE_NAME=processing|web|ai scripts/pi_setup.sh" ;;
    esac
  fi
  set_env CANARY_NODE_NAME "$node"
  set_env CANARY_NODE_IP "$(node_ip "$node")"
  # The AI HAT+ 2 (hailo-ollama, cluster/hailo-ollama.service) is on the AI Pi: only its backend
  # asks it. Elsewhere the dashboard would show an accelerator that is not there as offline.
  llm_url="http://host.docker.internal:11434"
  if [[ "$node" == ai ]]; then
    grep -q '^CANARY_LLM_URL=' "$ENV_FILE" || set_env CANARY_LLM_URL "$llm_url"
  elif [[ "$(env_value CANARY_LLM_URL)" == "$llm_url" ]]; then
    del_env CANARY_LLM_URL # copied from the AI Pi's .env
  fi
  note "this Pi is '$node' ($(node_ip "$node"))"
fi
chmod 600 "$ENV_FILE"
if [[ -n "${SUDO_UID:-}" ]]; then # run via sudo: keep .env readable by the real user
  chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$ENV_FILE"
fi

hub_password="$(env_value CANARY_MQTT_PASSWORD)"
[[ -n "$hub_password" ]] || die "CANARY_MQTT_PASSWORD in $ENV_FILE is empty"
[[ "$hub_password" != *[[:space:]]* ]] || die "CANARY_MQTT_PASSWORD in $ENV_FILE must not contain spaces"

# ---------------------------------------------------------------- 2. broker users
if ! docker image inspect "$MOSQUITTO_IMAGE" >/dev/null 2>&1; then
  note "pulling $MOSQUITTO_IMAGE ..."
  docker pull -q "$MOSQUITTO_IMAGE" >/dev/null
fi

existing_users="$(in_mosquitto 'cut -d: -f1 /mosquitto/config/passwd 2>/dev/null || true' </dev/null)"

names=("$HUB_USER") # users to (re)write, with their passwords
passwords=("$hub_password")
issued=()
kept=()
for sensor in ${sensors[@]+"${sensors[@]}"}; do
  if [[ $rotate -eq 0 ]] && grep -qxF -- "$sensor" <<<"$existing_users"; then
    kept+=("$sensor")
    continue
  fi
  names+=("$sensor")
  passwords+=("$(rand_hex 12)")
  issued+=("$sensor")
done

# Runs inside the container. Reads "user password" lines on stdin. The file is
# root-owned while mosquitto_passwd edits it (keeps it from warning about the
# owner), then handed to the broker's user: Mosquitto drops to the "mosquitto"
# user (uid 1883) before it reads the password file.
# shellcheck disable=SC2016 # the $variables belong to the container's shell
set_passwords='
set -eu
umask 077
f=/mosquitto/config/passwd
if [ -f "$f" ]; then chown 0:0 "$f"; else : >"$f"; fi
while read -r user pass; do
  printf "%s\n%s\n" "$pass" "$pass" | mosquitto_passwd "$f" "$user" >/dev/null
done
chown 1883:1883 "$f"
chmod 600 "$f"
'
for i in "${!names[@]}"; do
  printf '%s %s\n' "${names[$i]}" "${passwords[$i]}"
done | in_mosquitto "$set_passwords"
# The broker also needs to read the (committed) config and enter the directory
# (only matters for checkouts made with a restrictive umask).
chmod a+rx "$CONF_DIR" 2>/dev/null || true
chmod a+r "$CONF_DIR/mosquitto.conf" 2>/dev/null || true
note "broker users updated in mosquitto/config/passwd: $HUB_USER${issued[*]+ ${issued[*]}}"

compose=(docker compose -f "$ROOT/docker-compose.yml")
if "${compose[@]}" ps --status running --services 2>/dev/null | grep -qx mosquitto; then
  "${compose[@]}" kill -s SIGHUP mosquitto >/dev/null 2>&1 &&
    note "reloaded the running broker: new passwords work now"
fi

# ---------------------------------------------------------------- 3. what to type where
# Sensors and clients use the name the "announcer" service publishes over mDNS: it follows the
# Pi that holds the hub and its current address, whatever subnet the hotspot hands out.
hub_host="${CANARY_HUB_HOST:-canary-hub.local}"
this_ip="$(lan_ip)"
http_port="$(env_value CANARY_HTTP_PORT)"
web_url="http://$hub_host/"
if [[ -n "$http_port" && "$http_port" != "80" ]]; then
  web_url="http://$hub_host:$http_port/"
fi

echo
echo "== Canary hub ================================================================"
echo "Broker     : $hub_host:1883 (plaintext MQTT: trusted LAN / IoT VLAN only)"
echo "             this Pi right now: $this_ip:1883 (changes with the hotspot; prefer the name)"
echo "Secrets    : $ENV_FILE (mode 600) and mosquitto/config/passwd - never commit them"
if [[ $cluster -eq 1 ]]; then
  echo "Tip        : the three Pi addresses and the floating IP are fixed and outside the hotspot's range; sensors and the app find the hub as canary-hub.local."
else
  echo "Tip        : sensors and the app find the hub as canary-hub.local (the announcer service); no reserved address needed."
fi

for i in "${!names[@]}"; do
  [[ "${names[$i]}" != "$HUB_USER" ]] || continue
  echo
  echo "-- Sensor '${names[$i]}': enter in its setup portal ------------------------------"
  echo "   (Wi-Fi 'canary-setup' / 'water-sensor-setup'; reopen it by holding the config"
  echo "    button while the device boots - see the firmware README)"
  echo "   MQTT enabled (0 or 1)               : 1"
  echo "   MQTT host                           : $hub_host"
  echo "   MQTT port                           : 1883"
  echo "   MQTT user                           : ${names[$i]}"
  echo "   MQTT password (leave blank to keep) : ${passwords[$i]}"
  echo "   MQTT base topic                     : ${names[$i]}   (unique per device)"
done
if [[ ${#issued[@]} -gt 0 ]]; then
  echo
  echo "These sensor passwords are shown only now: store them (e.g. a password manager)."
  echo "Lost one? scripts/pi_setup.sh --rotate <sensor-user> issues a new one."
fi
if [[ ${#kept[@]} -gt 0 ]]; then
  echo
  echo "Unchanged (already configured): ${kept[*]}. Use --rotate to issue new passwords."
fi
if [[ ${#sensors[@]} -eq 0 ]]; then
  echo
  echo "Add sensors with: scripts/pi_setup.sh air-kitchen water-kitchen"
fi

if [[ $cluster -eq 1 ]]; then
  # scp / ssh targets: same user and checkout path on every Pi.
  user="${SUDO_USER:-$(id -un)}"
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
  home="${home:-$HOME}"
  remote_root="$ROOT"
  if [[ "$ROOT" == "$home"/* ]]; then remote_root="${ROOT#"$home"/}"; fi
  echo
  echo "== Three Pis (RUNME.md section 3) ============================================="
  echo "This Pi    : $node ($(node_ip "$node"))"
  echo "Pis        : processing $(node_ip processing), web $(node_ip web), ai $(node_ip ai)"
  echo "Floating IP: $(env_value CANARY_VIP)   (front door: held by web, else processing, else ai)"
  echo
  # The cluster addresses are fixed extra addresses on each Pi's Wi-Fi profile, so a new hotspot
  # (same SSID, another subnet) does not break etcd, Patroni or keepalived. Once per Pi, with sudo.
  wifi_profile="$(nmcli -t -f NAME,TYPE con show --active 2>/dev/null |
    awk -F: '$2 == "802-11-wireless" { print $1; exit }' || true)"
  wifi_profile="${wifi_profile:-<wifi-profile>}"
  echo "Fixed addresses, once on each Pi (Wi-Fi profile here: '$wifi_profile'; on another Pi:"
  echo "nmcli -t -f NAME,TYPE con show --active):"
  for name in processing web ai; do
    echo "   $name: sudo nmcli con mod '$wifi_profile' +ipv4.addresses $(node_ip "$name")/24 && sudo nmcli con up '$wifi_profile'"
  done
  echo
  echo "All three Pis use the same .env and mosquitto/config/passwd. After --cluster, new sensors"
  echo "or --rotate on this Pi, copy both to the other two (same user and checkout path assumed)"
  echo "and run scripts/pi_setup.sh there (it picks that Pi's role and reloads its broker):"
  echo "   cd $ROOT"
  for name in processing web ai; do
    [[ "$name" != "$node" ]] || continue
    target="$user@$(node_ip "$name")"
    echo "   scp .env $target:$remote_root/.env"
    echo "   sudo cat mosquitto/config/passwd | ssh $target 'umask 077; sudo tee $remote_root/mosquitto/config/passwd >/dev/null'"
  done
  if [[ ${#issued[@]} -gt 0 ]]; then
    echo "   (the new sensor logins work only on this Pi's broker until passwd is copied)"
  fi
  echo
  echo "Next       : docker compose up -d --build   on all three Pis, within a few minutes of each other"
  echo "Cluster    : docker compose exec postgres patronictl list   (one Leader, a Sync Standby, a Replica)"
else
  echo
  echo "Next       : docker compose up -d --build     (first build on a Pi takes a few minutes)"
fi
echo "Dashboard  : $web_url   (sign in as mihai, dispecer or admin)"
echo "API docs   : ${web_url}docs"
updater_user="${SUDO_USER:-$(id -un)}"
if [[ $cluster -eq 1 ]]; then where="on every Pi"; else where="once"; fi
echo "Updates    : install the updater $where (Administration -> Hub, scripts/hub_update.sh):"
echo "   sudo cp $ROOT/cluster/canary-updater.service /etc/systemd/system/"
echo "   sudo sed -i 's|^User=.*|User=$updater_user|' /etc/systemd/system/canary-updater.service"
echo "   sudo sed -i 's|^WorkingDirectory=.*|WorkingDirectory=$ROOT/cluster|' /etc/systemd/system/canary-updater.service"
echo "   sudo systemctl daemon-reload && sudo systemctl enable --now canary-updater"
echo "Mobile app : finds the hub on the Wi-Fi by itself (flutter build apk --release; no address)"
echo "Watch MQTT : RUNME.md, section 'Verify the sensors'"

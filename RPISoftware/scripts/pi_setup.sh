#!/usr/bin/env bash
# Canary hub setup. Run it once on the Raspberry Pi (or a laptop with Docker),
# and again whenever you add a sensor. Safe to re-run: it never changes an
# existing secret unless asked to.
#
#   scripts/pi_setup.sh                              # secrets + broker user "hub"
#   scripts/pi_setup.sh air-kitchen water-kitchen    # ... plus one MQTT user per sensor
#   scripts/pi_setup.sh --rotate air-kitchen         # new password for an existing sensor
#
# It:
#   1. creates RPISoftware/.env (mode 600) with a random CANARY_JWT_SECRET and
#      CANARY_MQTT_PASSWORD (the backend's broker password) when missing;
#   2. writes mosquitto/config/passwd with user "hub" and every sensor user named
#      on the command line (new sensors get a random password, existing ones keep
#      theirs unless --rotate). mosquitto_passwd runs in a throwaway
#      eclipse-mosquitto:2 container and gets the passwords on stdin, never as
#      command-line arguments, so nothing but Docker is needed on the Pi;
#   3. makes that file readable by the broker only (uid 1883, mode 600) and
#      reloads the broker if it is running;
#   4. prints what to type into each ESP32's setup portal, and the hub URLs.
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

  sensor-user   MQTT user for one ESP32 sensor, e.g. air-kitchen or water-kitchen
                (1-32 letters, digits, '-' or '_'). Use the same text as the
                device's "MQTT base topic": every device needs a unique one.
  --rotate      issue new passwords for the listed sensors even if they exist.

Environment: CANARY_HUB_HOST=<ip-or-name> overrides the detected LAN address
that is printed for the sensors' "MQTT host" field.
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

# ---------------------------------------------------------------- arguments
rotate=0
sensors=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --rotate) rotate=1 ;;
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
if ! grep -q '^CANARY_MQTT_PASSWORD=' "$ENV_FILE"; then
  printf 'CANARY_MQTT_PASSWORD=%s\n' "$(rand_hex 16)" >>"$ENV_FILE"
  note "generated CANARY_MQTT_PASSWORD (broker user '$HUB_USER')"
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
hub_host="${CANARY_HUB_HOST:-$(lan_ip)}"
http_port="$(env_value CANARY_HTTP_PORT)"
web_url="http://$hub_host/"
if [[ -n "$http_port" && "$http_port" != "80" ]]; then
  web_url="http://$hub_host:$http_port/"
fi

echo
echo "== Canary hub ================================================================"
echo "Broker     : $hub_host:1883 (plaintext MQTT: trusted LAN / IoT VLAN only)"
echo "Secrets    : $ENV_FILE (mode 600) and mosquitto/config/passwd - never commit them"
case "$hub_host" in
  "<pi-ip>" | 127.*)
    echo "WARNING    : could not detect the Pi's LAN address (got '$hub_host')."
    echo "             Re-run with CANARY_HUB_HOST=<pi-lan-ip> scripts/pi_setup.sh ..."
    ;;
esac
echo "Tip        : give the Pi a DHCP reservation / static IP: the sensors store this address."

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

echo
echo "Next       : docker compose up -d --build     (first build on a Pi takes a few minutes)"
echo "Dashboard  : $web_url   (sign in as mihai, dispecer or admin)"
echo "API docs   : ${web_url}docs"
echo "Mobile app : flutter run --dart-define=CANARY_API=${web_url%/}"
echo "Watch MQTT : RUNME.md, section 'Verify the sensors'"

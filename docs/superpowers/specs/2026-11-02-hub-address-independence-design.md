# Hub that survives a new hotspot phone: design

Date: 2026-11-02. Status: draft for approval.

## Why

The three-Pi hub (RUNME.md section 3) runs on the Wi-Fi hotspot `A54`. The owner replaced the phone
that provides the hotspot with another phone using the same SSID. The new phone hands out a
different subnet (`10.247.177.0/24` instead of `10.91.13.0/24`), and the hub broke:

- `.env` pins every cluster address (`CANARY_VIP=10.91.13.240`, processing `.170`, web `.188`,
  ai `.241`). On `canary2` and `canary3` etcd and Patroni die with `listen tcp 10.91.13.170:2380:
  bind: cannot assign requested address`, so there is no Postgres primary and the backend answers
  502. `canary` (ai) survived only because it carries `10.91.13.241` as a static extra address on
  its `A54` NetworkManager profile (`netplan-wlan0-A54`).
- Sensors store the hub's IP as their MQTT host; the mobile app has the hub URL compiled in
  (`--dart-define=CANARY_API`, `mobile/lib/src/config.dart`). Both point at an address that no
  longer exists.

The owner wants the hub, the sensors **and** the app to keep working, without re-entering
addresses or rebuilding anything, when the hotspot phone (and so the subnet) changes.

## Goals

1. **The cluster ignores the hotspot's subnet.** etcd, Patroni, pgproxy and keepalived keep working
   on their current `10.91.13.x` addresses whatever subnet the phone hands out.
2. **Sensors find the hub by name.** The MQTT host in each sensor's portal is `canary-hub.local`,
   which always points at the Pi that currently holds the hub role, at that Pi's real current
   address. After a failover the name moves; sensors reconnect to the new Pi.
3. **The app finds the hub by itself.** On start, and whenever the saved hub stops answering, the
   app discovers the hub on the network and remembers it. No rebuild after a phone swap.
4. **The dashboard is at `http://canary-hub.local/`** from a laptop on the same Wi-Fi.
5. Existing cluster data (etcd, Postgres) is kept. No re-bootstrap.

## Non-goals

- Changing SSID or Wi-Fi password. The owner keeps the same SSID; the Pis' NetworkManager profile
  `A54` matches it by SSID. A different SSID still needs the Pis reconfigured (out of scope).
- Making the app work when it runs on the phone providing the hotspot. The owner confirmed the app
  runs on a **different** phone connected to the hotspot.
- Discovery across subnets or over the internet.
- The single-Pi hub keeps working as today; it gets the name announcement (goal 2–4) but nothing
  about it is required to change.

## Anti-goals (a failure even if it technically works)

- Re-entering addresses in every sensor or rebuilding the app after each phone swap.
- Two Pis announcing `canary-hub.local` at the same time for longer than a failover takes.
- Wiping or re-initialising etcd/Patroni data to make addresses fit.

## Constraints and facts found

- All Pis are on Wi-Fi (`wlan0`; `eth0` is down), on the same hotspot. The phone forwards traffic
  between its clients (verified: laptop ↔ Pis and Pi ↔ Pi on the new subnet).
- **Unverified, verify first:** that the new phone also forwards traffic between clients using
  addresses it did not assign (`10.91.13.x` on both ends). The Pis are on one Wi-Fi network, so ARP
  between them should work; some hotspots filter it.
- `sudo` on the Pis needs a password. Every host-level change (NetworkManager, packages) is a step
  the owner runs, or a script the owner runs with sudo.
- The Pis already run `avahi-daemon` (that is how `canary.local`, `canary2.local`, `canary3.local`
  resolve).
- keepalived runs in a container with `network_mode: host`; its notify script
  (`cluster/keepalived/notify.sh`) writes `MASTER|BACKUP|FAULT|STOP` to `/run/canary/vrrp_state` on
  the `cluster_state` volume.
- Sensors pass `mqttHost` (≤64 chars) to `PubSubClient::setServer` as a hostname
  (`air_sensor/MqttService.cpp:273`), so the name is looked up on every connect attempt. Whether the
  ESP32 Arduino core's `WiFi.hostByName` resolves `*.local` is **not verified**.
- Sensors already advertise `_canary._tcp` (`water_sensor/NetworkConfig.cpp:373`). The hub must use
  a different service type so the app and tools never confuse a sensor with the hub.
- The app already depends on `shared_preferences`. It has an iOS build too (critical alerts).

## Design

### 1. Fixed cluster addresses (host network config, no code)

Each Pi carries its `.env` address (`CANARY_NODE_IP`) as an extra static IPv4 address `/24` on its
`A54` NetworkManager profile, next to the DHCP address from the phone:

```
sudo nmcli con mod A54 +ipv4.addresses 10.91.13.170/24 && sudo nmcli con up A54   # canary2
sudo nmcli con mod A54 +ipv4.addresses 10.91.13.188/24 && sudo nmcli con up A54   # canary3
```

(`canary` already has `.241`; the profile name on it is `netplan-wlan0-A54`.) No gateway on these
addresses; the default route stays on the phone's DHCP.

The VIP `10.91.13.240` stays as is and keeps doing what it does inside the cluster (the processing
Pi's backend reaches the broker through `CANARY_MQTT_HOST`). Sensors and the app stop using it.

`scripts/pi_setup.sh --cluster` gains this as a step: it prints the `nmcli` line for each Pi (and,
run with sudo on a Pi, applies it to that Pi's active Wi-Fi profile). The printed sensor portal
values change from the VIP to `canary-hub.local`. RUNME.md section 3 is updated: pick a private
`/24` the hotspot will not hand out (the existing `10.91.13.0/24` for this hub) instead of "DHCP
reservations".

### 2. `canary-hub.local` and the hub service (new compose service `announcer`)

A small new service, in the default profile (runs on one Pi too), `network_mode: host`, mounts the
host's D-Bus socket (`/run/dbus/system_bus_socket`) and, read-only, the `cluster_state` volume. It
uses the host's avahi-daemon (`avahi-publish` from `avahi-utils`, or the D-Bus API).

Loop, every 2 s:

- **Should this Pi announce?** Three Pis: `vrrp_state` is `MASTER`. One Pi: always.
- **Which address?** The IPv4 address on the interface carrying the default route (the phone's
  DHCP address), never `10.91.13.x`. Recomputed each loop, so a phone swap without a reboot is picked
  up.
- When it should announce: publish
  - address record `canary-hub.local → <address>`
  - service `_canary-hub._tcp`, port 8000, instance name "Canary hub", TXT
    `api=http://<address>:8000`, `node=<CANARY_NODE_NAME>`.
- When it should not, or the address changed: withdraw (kill the `avahi-publish` processes / free
  the entry group) before publishing anything new.

On container stop it withdraws. avahi handles a name conflict by refusing the second publisher;
the announcer logs that and retries next loop, so a short overlap during failover resolves itself
once the old MASTER drops to BACKUP.

Why not inside keepalived's notify script: the notify runs only on state changes, and the address
must also follow DHCP changes while the state stays `MASTER`.

`CANARY_PUBLIC_URL` (base of household invite links) becomes `http://canary-hub.local` in cluster
mode (`pi_setup.sh`).

### 3. Sensors

The MQTT host in each sensor's portal becomes `canary-hub.local`. Nothing else changes in the portal.

Firmware: first verify on hardware whether `WiFi.hostByName("canary-hub.local")` resolves (the log
line in `MqttService.cpp` prints `-> unresolved` when it does not). If it does not, both sensor
firmwares resolve names ending in `.local` with `MDNS.queryHost()` (ESPmDNS is already started in
`NetworkConfig.cpp`) before `connect`, and pass the IP to `setServer`. Look-up on every connect
attempt, never cached across a failed connect, so a failover is followed. Covered by native tests
for the "is this a `.local` name" decision; the query itself is checked on hardware. A firmware
change means each sensor is reflashed once.

### 4. Mobile app discovery

New `HubLocator` in the app:

1. On start: if a hub URL is saved (`shared_preferences`), probe `<url>/health` (2 s timeout). It
   answers with `"service":"canary-backend"` → use it.
2. Otherwise, or when the API client sees the hub unreachable (connection error / timeout on
   consecutive requests): browse `_canary-hub._tcp` for up to 5 s, take the `api` TXT value (or the
   resolved host + port), probe `/health`, use and save the first that answers.
3. Nothing found: scan the phone's own Wi-Fi `/24` (from the Wi-Fi IP), probing
   `http://<ip>:8000/health` with ~30 requests in flight and a 600 ms timeout; first
   `canary-backend` wins.
4. Still nothing: show "Looking for the hub…" with a retry button and a field to type an address by
   hand (saved like a discovered one).

`--dart-define=CANARY_API`, when given, skips discovery entirely (development builds). The settings
and onboarding screens show the address in use (today they show the compile-time constant).

The API client's base URL becomes the located URL instead of `Config.apiBase`.

Platform needs: Android `INTERNET` + `CHANGE_WIFI_MULTICAST_STATE`; iOS `NSLocalNetworkUsageDescription`
and `NSBonjourServices` listing `_canary-hub._tcp`.

### 5. Order of work

1. Owner adds the static addresses to `canary2` and `canary3` (section 1). Verify:
   `ping 10.91.13.241` from both, `docker compose exec postgres patronictl list` shows Leader + Sync
   Standby + Replica. This also restores today's hub.
2. Announcer service + `pi_setup.sh` / RUNME changes.
3. Firmware check, fix only if needed; sensors re-pointed to `canary-hub.local`.
4. App discovery.

### 6. Decisions from the review

- **If step 1's check fails** (the phone drops traffic between Pis on `10.91.13.x`): stop after
  step 1 and come back to the owner. Do not build the announcer on top of it: keepalived's VRRP is
  unicast between the `10.91.13.x` addresses (`cluster/keepalived/entrypoint.sh`), so a blocked
  network makes every Pi MASTER and all three would announce `canary-hub.local`. As a safety net
  regardless, the announcer only announces when this Pi is MASTER **and** its etcd member sees a
  quorum (`/health` of local etcd); a Pi that is MASTER without quorum stays silent.
- **`CANARY_API` in release builds:** it is the first address to try, not a switch that turns
  discovery off. When it stops answering, discovery runs as for any saved address. `mobile/README.md`
  and RUNME.md drop the define from the release build instructions; it stays documented for
  development.
- **Household invite links:** the backend builds the `url` of an invite from the address the
  request came in on (scheme + `Host` header), falling back to `CANARY_PUBLIC_URL`; `app_url`
  (`canary://join/<code>`) is unchanged. The person creating the invite reached the hub somehow,
  so that address works on the same Wi-Fi; Android browsers do not resolve `.local`.
  `CANARY_PUBLIC_URL` is then only the fallback and stays as `pi_setup.sh` writes it.
- **The Pis' own names** (`canaryN.local`) will also advertise the `10.91.13.x` address. Accepted:
  the app uses the `api` TXT value (the routable address), not the host name, and the
  `canary-hub.local` record carries only the routable address. No host-level avahi change.

## Left to the builder

- Shell vs Python for the announcer, and `avahi-publish` processes vs the D-Bus API.
- Flutter package for DNS-SD browsing (it must support Android and iOS).
- Exact unreachable-detection threshold in the app.
- Whether `pi_setup.sh` applies the `nmcli` change itself or only prints it.

## Calls made by Claude (not discussed with the owner)

- Keep `10.91.13.0/24` as the fixed cluster range (no `.env` or etcd change).
- `_canary-hub._tcp` as the service type, separate from the sensors' `_canary._tcp`.
- The announcer is a compose service polling `vrrp_state`, not a keepalived notify hook.
- The `/24` scan stays as a fallback even though the app runs on a separate phone.

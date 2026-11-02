# Hub address independence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The three-Pi hub, the sensors and the mobile app keep working when the hotspot phone (and so the Wi-Fi subnet) changes.

**Architecture:** The Pis talk to each other on fixed `10.91.13.x` addresses added to their Wi-Fi profile (done by hand, already applied). A new `announcer` compose service publishes `canary-hub.local` and the `_canary-hub._tcp` service over the host's avahi-daemon from whichever Pi holds the hub role, at that Pi's routable DHCP address. Sensors use the name; the app discovers the service (falling back to a subnet scan) and remembers the result.

**Tech Stack:** Python 3 + `avahi-publish` in an Alpine container; FastAPI backend; Flutter app (Riverpod, dio, shared_preferences); ESP32 Arduino firmware (only if the hardware check fails).

**Spec:** `docs/superpowers/specs/2026-11-02-hub-address-independence-design.md`

## Global Constraints

- Hub name: `canary-hub.local`. Service type: `_canary-hub._tcp`, port `8000`, instance name `Canary hub`, TXT `api=http://<address>:8000` and `node=<CANARY_NODE_NAME>`.
- Never announce a `10.91.13.x` (cluster) address; announce the address on the default route.
- Three Pis: announce only when `vrrp_state` is `MASTER` **and** the local etcd reports healthy (quorum). One Pi: always announce.
- Cluster addresses, `.env` and etcd/Patroni data are not changed.
- Existing sensor service `_canary._tcp` is untouched.
- App: `--dart-define=CANARY_API` is the first address to try, never a switch that disables discovery.
- A hub is accepted only if `GET <base>/health` returns JSON with `"service": "canary-backend"`.
- Invite `url` = scheme and port of `CANARY_PUBLIC_URL`, host from the request's `Host` header (port stripped); `app_url` unchanged.
- The Pis' `sudo` needs a password: every host-level step is an owner step, written out as a command.
- `canary` and `canary3` have no GitHub credentials: deploy by pushing `main` from the laptop (`git push canary@<pi-ip>:canary-firmware origin/main:refs/remotes/origin/main`), as done on 2026-11-02. SSH to the Pis by their DHCP address, not `canaryN.local` (it may resolve to an unreachable `10.91.13.x`).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Phone swapped while the Pis keep running** (DHCP address changes, no reboot): the announcer must withdraw the old address and publish the new one within one loop. Test: `test_address_change_republishes` (Task 1).
2. **Failover overlap** (two Pis MASTER for a few seconds, avahi refuses the second publisher, `avahi-publish` exits): the announcer must keep retrying, not give up. Test: `test_exited_publisher_is_restarted` (Task 1).
3. **avahi-daemon or the D-Bus socket missing** (fresh Pi, `avahi-daemon` stopped): the announcer logs and retries every loop without crashing. Test: `test_spawn_failure_is_retried` (Task 1).
4. **Something else answers on port 8000** during the app's scan or at a stale saved address: it must not be taken for the hub. Test: `rejects a responder that is not canary-backend` (Task 3).
5. **Invite created from the app, which talks to port 8000 directly** (`Host: 10.247.177.188:8000`): the link must point at the dashboard port, not 8000. Test: `test_invite_url_uses_request_host_and_public_port` (Task 2).

---

### Task 1: Announcer service

**Files:**
- Create: `RPISoftware/cluster/announcer/announcer.py`
- Create: `RPISoftware/cluster/announcer/Dockerfile`
- Create: `RPISoftware/cluster/announcer/test_announcer.py`
- Modify: `RPISoftware/docker-compose.yml` (new service `announcer`, default profile)
- Modify: `RPISoftware/scripts/smoke.sh` (run the announcer tests in the "Hub infra" block)

**Interfaces:**
- Produces: the `canary-hub.local` A record and `_canary-hub._tcp` service on the LAN (Tasks 3, 4 and 5 rely on them).
- Functions in `announcer.py` (pure, tested):
  - `should_announce(cluster_mode: str, vrrp_state: str | None, etcd_healthy: bool) -> bool`
  - `routable_ipv4(route_get_output: str, cluster_ips: set[str]) -> str | None` — parses the `src` of `ip -4 route get 1.1.1.1`; returns None if absent or in `cluster_ips`.
  - `publish_commands(address: str, node: str) -> list[list[str]]` — exactly:
    `["avahi-publish", "-a", "-R", "canary-hub.local", address]` and
    `["avahi-publish", "-s", "Canary hub", "_canary-hub._tcp", "8000", f"api=http://{address}:8000", f"node={node}"]`
  - `class Publisher(spawn: Callable[[list[str]], Proc])` with `apply(target: tuple[str, str] | None) -> None` (target = `(address, node)` or None to withdraw). Starts the commands when the target changes, kills the previous ones first, restarts any that exited, and catches `OSError` from `spawn` (logs, retries next call). `Proc` is anything with `poll()` and `terminate()`.
- Main loop (untested glue): every 2 s read `/run/canary/vrrp_state` (missing → None), probe `http://127.0.0.1:2379/health` (timeout 1 s, healthy iff JSON `health == "true"`; skipped in one-Pi mode), run `ip -4 route get 1.1.1.1`, call `Publisher.apply`. SIGTERM → `apply(None)` then exit. Env: `CANARY_CLUSTER_MODE`, `CANARY_NODE_NAME` (default `hub`), `CANARY_VIP`, `CANARY_PROCESSING_IP`, `CANARY_WEB_IP`, `CANARY_AI_IP`.

- [ ] **Step 1: Write the failing tests** in `test_announcer.py` (plain pytest, fake `Proc` with a settable `poll()` return and a `terminated` flag; fake `spawn` that records commands):

```python
def test_should_announce():
    assert should_announce("", None, False)                    # one Pi: always
    assert should_announce("triple", "MASTER", True)
    assert not should_announce("triple", "MASTER", False)      # no quorum: stay silent
    assert not should_announce("triple", "BACKUP", True)
    assert not should_announce("triple", None, True)

def test_routable_ipv4():
    out = "1.1.1.1 via 10.247.177.226 dev wlan0 src 10.247.177.188 uid 1000\n    cache"
    assert routable_ipv4(out, set()) == "10.247.177.188"
    assert routable_ipv4(out, {"10.247.177.188"}) is None
    assert routable_ipv4("RTNETLINK answers: Network is unreachable", set()) is None

def test_publish_commands_exact(): ...          # the two lists from Interfaces, for ("10.0.0.5", "web")
def test_apply_starts_once():                    # apply(t) twice -> 2 spawns total
def test_apply_none_withdraws():                 # both procs terminated, nothing new spawned
def test_address_change_republishes():           # apply(("a","web")) then apply(("b","web")) -> old 2 terminated, 2 new with "b"
def test_exited_publisher_is_restarted():        # proc.poll() returns 1 -> next apply(same) respawns that command only
def test_spawn_failure_is_retried():             # spawn raises OSError once -> no exception; next apply spawns
```

- [ ] **Step 2: Run them, expect import failure**

Run: `cd RPISoftware/cluster/announcer && python3 -m pytest -q test_announcer.py`
Expected: FAIL, `ModuleNotFoundError: No module named 'announcer'`

- [ ] **Step 3: Implement `announcer.py`** with the functions above and the main loop. Standard library only (`subprocess`, `urllib.request`, `json`, `signal`, `time`).

- [ ] **Step 4: Run the tests, expect pass**

Run: `cd RPISoftware/cluster/announcer && python3 -m pytest -q test_announcer.py`
Expected: `8 passed`

- [ ] **Step 5: Dockerfile + compose service + smoke**

Dockerfile: `FROM alpine:3.24.2`, `apk add --no-cache python3 avahi-tools iproute2`, copy `announcer.py`, `CMD ["python3", "-u", "/announcer.py"]`.
Compose service `announcer`: `build: ./cluster/announcer`, **no** `profiles` (runs on one Pi too), `network_mode: host`, `restart: unless-stopped`, environment as in Interfaces (`${VAR:-}` style like keepalived), volumes `/run/dbus/system_bus_socket:/run/dbus/system_bus_socket` and `cluster_state:/run/canary:ro`, `logging: *logging`. In smoke.sh's "Hub infra" block add `python3 -m pytest -q cluster/announcer/test_announcer.py || exit 1` (the backend venv is not active there; use the system `python3 -m pytest` if present, else skip with a printed note, matching the compose check's style).

Run: `bash RPISoftware/scripts/smoke.sh`
Expected: last line `SMOKE: PASS`

- [ ] **Step 6: Commit**

```bash
git add RPISoftware/cluster/announcer RPISoftware/docker-compose.yml RPISoftware/scripts/smoke.sh
git commit -m "Announce the hub as canary-hub.local from the Pi that holds it"
```

---

### Task 2: Invite links follow the address the hub was reached on

**Files:**
- Modify: `RPISoftware/backend/app/api/household.py:122-155` (`create_invite`)
- Test: `RPISoftware/backend/tests/test_household.py:57`

**Interfaces:**
- Produces: `invite_url(public_url: str, host_header: str | None, code: str) -> str` in `household.py`. No host header → `f"{public_url.rstrip('/')}/join/{code}"` (today's behaviour).

- [ ] **Step 1: Write the failing tests**

```python
def test_invite_url_uses_request_host_and_public_port():
    assert invite_url("http://canary-hub.local", "10.247.177.188:8000", "c") == "http://10.247.177.188/join/c"
    assert invite_url("http://10.91.13.240:8080", "10.247.177.188", "c") == "http://10.247.177.188:8080/join/c"
    assert invite_url("http://localhost", None, "c") == "http://localhost/join/c"
    assert invite_url("http://localhost", "[fe80::1]:8000", "c") == "http://[fe80::1]/join/c"
```

and change line 57 to expect `f"http://test/join/{invite['code']}"` (the test client's `base_url` is `http://test`).

- [ ] **Step 2: Run, expect fail**

Run: `cd RPISoftware/backend && .venv/bin/python -m pytest -q tests/test_household.py`
Expected: FAIL (`invite_url` not defined; line 57 still `localhost`)

- [ ] **Step 3: Implement `invite_url`** with `urllib.parse.urlsplit` on `public_url` for scheme and port; strip the port from the host header (keep IPv6 brackets). `create_invite` takes `request: Request` and passes `request.headers.get("host")`.

- [ ] **Step 4: Run, expect pass**

Run: `cd RPISoftware/backend && .venv/bin/python -m pytest -q tests/test_household.py`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add RPISoftware/backend/app/api/household.py RPISoftware/backend/tests/test_household.py
git commit -m "Build invite links from the address the hub was reached on"
```

---

### Task 3: App finds the hub by itself

**Files:**
- Create: `RPISoftware/mobile/lib/src/services/hub_locator.dart`
- Create: `RPISoftware/mobile/test/hub_locator_test.dart`
- Create: `RPISoftware/mobile/lib/src/ui/find_hub_screen.dart`
- Modify: `RPISoftware/mobile/lib/src/config.dart` (rename `apiBase` → `apiOverride`, default `''`; drop `wsBase`)
- Modify: `RPISoftware/mobile/lib/src/services/api_client.dart` (settable base URL, unreachable callback)
- Modify: `RPISoftware/mobile/lib/src/services/ws_client.dart:35` (base from the located URL)
- Modify: `RPISoftware/mobile/lib/src/services/storage.dart` (key `hub_url`)
- Modify: `RPISoftware/mobile/lib/src/state/providers.dart:44` (hub URL provider, wiring)
- Modify: `RPISoftware/mobile/lib/src/ui/onboarding_screen.dart:107`, `settings_screen.dart:127` (show the located address)
- Modify: `RPISoftware/mobile/lib/l10n/app_en.arb`, `app_ro.arb` (new strings)
- Modify: `RPISoftware/mobile/pubspec.yaml` (DNS-SD package, builder's choice, must support Android and iOS)
- Modify: `RPISoftware/mobile/android/app/src/main/AndroidManifest.xml` (`CHANGE_WIFI_MULTICAST_STATE`), `ios/Runner/Info.plist` (`NSLocalNetworkUsageDescription`, `NSBonjourServices` = `_canary-hub._tcp`)
- Modify: `RPISoftware/mobile/README.md:89`, `RPISoftware/RUNME.md` (release build without `CANARY_API`; section 3 step 7)

**Interfaces:**
- Consumes: `_canary-hub._tcp` with TXT `api` (Task 1).
- Produces in `hub_locator.dart`:
  - `typedef HubProbe = Future<bool> Function(String baseUrl);` — the default implementation GETs `<base>/health` (2 s timeout) and returns true only for `"service" == "canary-backend"`.
  - `typedef HubBrowse = Future<List<String>> Function(Duration timeout);` — base URLs from the `api` TXT values (fallback: `http://<resolved host>:<port>`).
  - `typedef WifiIpv4 = Future<String?> Function();` — default: first non-loopback IPv4 of `NetworkInterface.list()`.
  - `class HubLocator({required HubProbe probe, required HubBrowse browse, required WifiIpv4 wifiIp, String override = '', String? saved})` with `Future<String?> locate()`: tries, in order, `override` (if non-empty), `saved`, each browse result (browse timeout 5 s), then the `/24` of `wifiIp()` (hosts .1–.254 except its own, `http://<ip>:8000`, at most 30 probes in flight, 600 ms timeout each). Returns the first base URL whose probe is true, else null.
  - `ApiClient.baseUrl` setter, `ApiClient.onUnreachable` callback fired after 2 consecutive requests that failed with no HTTP response (`statusCode == null`); a response resets the count.
  - `hubUrlProvider` (`StateProvider<String?>`): set by the locator, saved under `hub_url`, pushed into `ApiClient.baseUrl`; `onUnreachable` re-runs `locate()` (never two at once).
- `FindHubScreen`: shown while `hubUrlProvider` is null: "Looking for the hub…", a retry button, and a text field for an address typed by hand (accepted only if the probe passes; then saved like a discovered one).

- [ ] **Step 1: Write the failing tests** in `hub_locator_test.dart` with fake probe/browse/wifiIp (no network):

```dart
test('uses the override first, when it answers', ...)            // override ok -> override; browse never called
test('a dead override falls through to discovery', ...)            // override probe false, browse returns [u] -> u
test('saved address answers -> no browse', ...)
test('browse result that answers wins over the scan', ...)
test('falls back to scanning the /24', ...)                        // browse [], wifiIp 10.247.177.50, probe true only for http://10.247.177.188:8000 -> that URL; own .50 never probed
test('rejects a responder that is not canary-backend', ...)        // default HubProbe against a MockClient/HttpServer returning {"service":"other"} -> false; {"service":"canary-backend"} -> true
test('returns null when nothing answers', ...)                     // and probes at most 253 scan addresses
test('scan keeps at most 30 probes in flight', ...)                // fake probe tracks concurrent count; max <= 30
```

and in the same file an `ApiClient` test: two failed requests with no response fire `onUnreachable` once; a 500 in between resets the count.

- [ ] **Step 2: Run, expect fail**

Run: `cd RPISoftware/mobile && flutter test test/hub_locator_test.dart`
Expected: FAIL (compile error: `hub_locator.dart` missing)

- [ ] **Step 3: Implement `hub_locator.dart`** and the `ApiClient` changes.

- [ ] **Step 4: Run, expect pass**

Run: `cd RPISoftware/mobile && flutter test test/hub_locator_test.dart`
Expected: all pass

- [ ] **Step 5: Wire it in**: config rename, ws client, storage key, providers, `FindHubScreen`, onboarding/settings text, l10n (en + ro), manifest, Info.plist, docs. Every former use of `Config.apiBase` goes through `hubUrlProvider`.

Run: `cd RPISoftware/mobile && flutter analyze && flutter test && bash ../scripts/mobile_check.sh`
Expected: no analyzer issues; all tests pass

- [ ] **Step 6: Commit**

```bash
git add RPISoftware/mobile RPISoftware/RUNME.md
git commit -m "Find the hub on the network instead of a built-in address"
```

---

### Task 4: Setup script and docs speak names, not the floating IP

**Files:**
- Modify: `RPISoftware/scripts/pi_setup.sh:300-305` (cluster block), `:413-416` (hub host printed for sensors), the "Tip" lines after `:436`
- Modify: `RPISoftware/RUNME.md` section 3.1 (fixed private `/24` instead of DHCP reservations), 3.2 steps 2 and 7, section 1.4 example output
- Modify: `RPISoftware/docs/HARDWARE.md` (MQTT host may be `canary-hub.local`)

**Interfaces:**
- Consumes: the name from Task 1.
- Behaviour: in cluster mode `hub_host` defaults to `canary-hub.local` (still overridable by `CANARY_HUB_HOST`); `CANARY_PUBLIC_URL` default becomes `http://canary-hub.local` (+ `:port`); one-Pi mode also prints `canary-hub.local` as the broker host, with the detected LAN IP shown as the alternative. After `--cluster`, print for each Pi:
  `sudo nmcli con mod <wifi-profile> +ipv4.addresses <ip>/24 && sudo nmcli con up <wifi-profile>`
  where `<wifi-profile>` is the active Wi-Fi connection name from `nmcli -t -f NAME,TYPE con show --active` (fallback text `<wifi-profile>`). The script does not run `nmcli` itself.
- Tip line (cluster) becomes: `Tip        : the three Pi addresses and the floating IP are fixed and outside the hotspot's range; sensors and the app find the hub as canary-hub.local.`

- [ ] **Step 1: Make the changes.**

- [ ] **Step 2: Verify** syntax and the printed output in a scratch copy (no docker needed for the text):

Run: `bash -n RPISoftware/scripts/pi_setup.sh && bash RPISoftware/scripts/smoke.sh`
Expected: no output from `bash -n`; `SMOKE: PASS`

Then on `canary3` (owner has sudo; the script is safe to re-run): `cd ~/canary-firmware/RPISoftware && scripts/pi_setup.sh` and check that the portal block prints `MQTT host : canary-hub.local`.

- [ ] **Step 3: Commit**

```bash
git add RPISoftware/scripts/pi_setup.sh RPISoftware/RUNME.md RPISoftware/docs/HARDWARE.md
git commit -m "Point sensors and docs at canary-hub.local"
```

---

### Task 5: Deploy and verify on the Pis

No code. Depends on Tasks 1, 2 and 4 being on `main` (Task 3 is the app; it is verified in Task 7).

- [ ] **Step 1: Push and roll out**, one Pi at a time, `canary2` (processing) last but one, `canary` (Postgres leader) last:

```bash
git push origin main
for ip in 10.247.177.188 10.247.177.170 10.247.177.92; do
  git push canary@$ip:canary-firmware origin/main:refs/remotes/origin/main
  ssh canary@$ip 'cd ~/canary-firmware && git merge -q --ff-only origin/main && cd RPISoftware && scripts/pi_setup.sh && docker compose up -d --build'
  # pi_setup.sh writes CANARY_ANNOUNCE=1 (Raspberry Pi detected); without it the announcer stays silent
  # wait until `docker compose ps` shows every service healthy before the next Pi
done
```

- [ ] **Step 2: The name resolves from the laptop to the VIP holder's DHCP address**

Run: `avahi-resolve -4 -n canary-hub.local && avahi-browse -rt _canary-hub._tcp`
Expected: `canary-hub.local 10.247.177.188` (canary3 holds the VIP); the service shows `"api=http://10.247.177.188:8000"` `"node=web"`. Only one service instance.

- [ ] **Step 3: Failover moves the name.** On canary3: `docker compose stop keepalived`. Within ~10 s, `avahi-resolve -4 -n canary-hub.local` returns canary2's address (`10.247.177.170`) and `avahi-browse -rt _canary-hub._tcp` shows one instance with `node=processing`. Then `docker compose start keepalived`; after the 30 s `preempt_delay` the name returns to `10.247.177.188`.

- [ ] **Step 4: Dashboard by name.** `curl -s http://canary-hub.local/health` returns `"status":"ok"`.

---

### Task 6: Sensors connect by name (firmware fix only if needed)

**Files (only if Step 2 shows `unresolved`):**
- Modify: `air_sensor/Hostname.h`, `water_sensor/Hostname.h` (add `isMdnsName`)
- Create: `air_sensor/tests/native/hostname_test.cpp`, `water_sensor/tests/native/hostname_test.cpp`
- Modify: `air_sensor/scripts/run-native-tests.sh`, `water_sensor/scripts/run-native-tests.sh` (build and run the new test)
- Modify: `air_sensor/MqttService.cpp:271-275` and `water_sensor/MqttService.cpp:289-293` (resolve before connect)

**Interfaces:**
- `inline bool isMdnsName(const char* host)`: true iff `host` ends in `.local` (case-insensitive) and has at least one character before it.
- In `MqttService::connect`, before `mqttClient_.connect`: if `isMdnsName(networkConfig_.mqttHost)`, `MDNS.queryHost(<label without ".local">, 2000)`; a non-zero address → `mqttClient_.setServer(address, port)`; zero → log `[mqtt] could not resolve <host>` and treat as a failed connect (same backoff). Resolve on every attempt; never cache.

- [ ] **Step 1: Owner re-points one air sensor.** In its portal set MQTT host `canary-hub.local`, keep user/password/base topic.

- [ ] **Step 2: Check on hardware.** Watch its serial log.
  - `[mqtt] connected to canary-hub.local:1883` → the core resolves `.local`; **skip Steps 3–7** and go to Step 8.
  - `connect failed: host=canary-hub.local -> unresolved` → continue.

- [ ] **Step 3: Write the failing test** (`hostname_test.cpp`, same `CHECK` macro style as `display_model_test.cpp`):

```cpp
CHECK(isMdnsName("canary-hub.local"));
CHECK(isMdnsName("Canary-Hub.LOCAL"));
CHECK(!isMdnsName(".local"));
CHECK(!isMdnsName("10.247.177.188"));
CHECK(!isMdnsName("canary-hub.localdomain"));
CHECK(!isMdnsName(""));
CHECK(!isMdnsName(nullptr));
```

- [ ] **Step 4: Run, expect fail**

Run: `./air_sensor/scripts/run-native-tests.sh`
Expected: compile error, `isMdnsName` not declared

- [ ] **Step 5: Implement** `isMdnsName` in both `Hostname.h` and the resolve-before-connect in both `MqttService.cpp`.

- [ ] **Step 6: Run, expect pass**

Run: `./air_sensor/scripts/run-native-tests.sh && ./water_sensor/scripts/run-native-tests.sh`
Expected: both exit 0

- [ ] **Step 7: Commit, flash the test sensor, repeat Step 2** (expect `connected to canary-hub.local:1883`).

```bash
git add air_sensor water_sensor
git commit -m "Resolve a .local MQTT host over mDNS before connecting"
```

- [ ] **Step 8: Re-point every sensor** to `canary-hub.local` (and reflash each if Steps 3–7 ran). Check the dashboard's Sensors view shows every sensor online. Then repeat Task 5 Step 3 (failover) and confirm the sensors come back online on the other Pi within a minute.

---

### Task 7: App on a second phone

- [ ] **Step 1:** Build a release APK **without** `--dart-define=CANARY_API` (`cd RPISoftware/mobile && flutter build apk --release`), install on a phone joined to the hotspot (not the hotspot phone).
- [ ] **Step 2:** First start shows "Looking for the hub…" briefly, then the sign-in; Settings shows `http://10.247.177.188:8000`.
- [ ] **Step 3:** Failover by **powering off the hub Pi** (not just stopping keepalived: the old backend would keep answering): the app shows a short reconnect, live alarms come back on the new Pi, and Settings shows the new address. Power the Pi back on; after the 30 s preempt delay the app follows the name back.
- [ ] **Step 4:** Create a household invite in the app; the link is `http://10.247.177.188/join/<code>` and opens the join page in the phone's browser.

---

## Execution notes

- Tasks 1, 2, 3 and 4 are independent code changes; Task 5 needs 1, 2 and 4 merged; Task 6 needs Task 5; Task 7 needs Tasks 3 and 5.
- Steps that touch hardware (Task 5–7) need the owner present (sensor portals, phones, sudo).

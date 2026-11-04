# Canary — Resident App (Flutter)

Cross-platform (Android + iOS) resident app for the Canary safety platform:
emergency alerts, **evacuation guidance routed away from the hazard**, and an
**"I'm safe" check-in** that feeds backend victim-accounting.

Built from ARCHITECTURE.md **section D** (Flutter, local notifications with optional
FCM, offline check-in queue, presence consent; critical alerts need Apple's
entitlement). Its "As built" note lists what differs from the plan.

## Architecture

```
lib/
  main.dart                  app entry (init storage + notifications, ProviderScope)
  src/
    config.dart              API/WS base, building id, FCM flag (--dart-define overridable)
    theme.dart               hazard color language (normal/warning/alarm/evacuation)
    models/                  auth, incident, evacuation, check_in, summary (hub sensor analysis)
    services/
      api_client.dart        REST (dio): login, incidents, evacuation, checkin, sensor summary
      ws_client.dart         live incident stream (web_socket_channel) + auto-reconnect
      storage.dart           shared_preferences: session, consent, offline check-in queue
      notifications.dart     flutter_local_notifications (+ optional FCM)
      firebase_push.dart     isolated FCM init (critical-alert permission)
    state/                   Riverpod: session, incidents (+WS), sensor summary, evacuation, consent
    ui/                      onboarding (sign-in), home, alarm (full-screen), settings,
                             manager dashboard (managers / dispatchers / admins), widgets/
```

**State management:** Riverpod (`flutter_riverpod`). The incident controller merges
the REST snapshot with the live WebSocket stream, raises a heads-up notification on
entering an alarming state, and flushes the offline check-in queue on reconnect.

**Home status (hub sensors):** the home screen (and the manager dashboard, as
"Building sensors") shows the hub's *analysis* of the real ESP32 sensors from
`GET /api/v1/buildings/{id}/summary` — overall status, then per-zone cards with
each sensor's headline and indicators (air quality, CO, gas, comfort, leak, valve,
health; occupancy only for managers, dispatchers and admins: the hub never tells a
resident who is home); tap a sensor for details and advice. The app never shows
raw measurements (ppm, ADC, µg/m³, °C, %RH, RSSI) — those stay on the web
dashboard. Contract: [`../docs/HARDWARE.md`](../docs/HARDWARE.md). The summary
refreshes on WebSocket `node` / `incident` events (at most every 5 s), every 30 s
as a fallback, and on pull-to-refresh.

## Run (against the local backend)

The platform folders (`android/`, `ios/`) are included and carry the LAN
settings described below, so no `flutter create` is needed:

```bash
cd mobile
flutter pub get

# start the backend first, from RPISoftware/: scripts/pi_setup.sh once, then docker compose up -d
# Android emulator reaches the host at 10.0.2.2 (the default).
flutter run

# physical device / different host:
flutter run --dart-define=CANARY_API=http://<your-host-ip>:8000
```

Installing Flutter and the other laptop flows: [`../RUNME.md`](../RUNME.md) §2.5.

Log in as **`ana`** (seeded resident); the app takes the building from the hub. Then trigger a
hazard (from `RPISoftware/`; in Demo mode, or use "Simulate gas leak" on the dashboard):

```bash
docker compose --profile sim run --rm simulator --scenario gas_leak   # legacy demo sensors
docker compose --profile sim run --rm hw-sim --scenario co --fast     # firmware-accurate ESP32 nodes
```

The app receives the WebSocket `incident` event → raises a notification →
auto-opens the full-screen alarm → shows evacuation route + assembly point →
tap **"I'm safe / evacuated"** → backend unaccounted count drops.

## Run against the Raspberry Pi hub (LAN)

The Pi serves the API over plain HTTP on the local network: nginx on port 80
proxies `/api` and the WebSocket, and the backend itself listens on `:8000`.
Put the phone on the same Wi-Fi as the Pi and point the app at it (the WebSocket
URL is derived automatically, `http` → `ws`):

```bash
flutter run --dart-define=CANARY_API=http://<pi-ip>          # via nginx (:80)
flutter run --dart-define=CANARY_API=http://<pi-ip>:8000     # straight to the backend

# installable builds keep the same define
flutter build apk --release --dart-define=CANARY_API=http://<pi-ip>
flutter build ios --release --dart-define=CANARY_API=http://<pi-ip>
```

`CANARY_BUILDING` (default `bld_live`) is only the fallback building when the hub does not name
one. The app follows the hub's Demo / Real mode (see [`../docs/DEMO.md`](../docs/DEMO.md)).
The server URL is shown on the sign-in and settings screens.

- **Android:** the main manifest declares `INTERNET` (release builds need it; the
  debug/profile manifests only add it for the Flutter tool) and sets
  `android:usesCleartextTraffic="true"`, since Android blocks plain HTTP by
  default and the hub's private IP can't be listed in a per-domain network
  security config. (Flutter's own HTTP/WebSocket stack doesn't enforce that
  policy today; the flag keeps it working if that changes.)
- **iOS:** the first time the app contacts the Pi, iOS asks for **Local Network**
  access. Allow it, or the app can't reach the Pi (re-enable it in Settings →
  Privacy & Security → Local Network). `Info.plist` sets
  `NSAppTransportSecurity` → `NSAllowsLocalNetworking` (a narrow ATS exception,
  not `NSAllowsArbitraryLoads`).

## Platform configuration (required for real device features)

### Android — `android/app/src/main/AndroidManifest.xml`
Already set: `INTERNET` and `android:usesCleartextTraffic="true"` (LAN hub, see above).
For the full alarm experience also add:
```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>
```
The high-importance `canary_alarm` channel + `fullScreenIntent` let critical alerts
surface over the lock screen. Note OEM battery killers (Xiaomi/Huawei/Oppo, common in
RO) can still delay background push — the **physical guarantee is the edge siren +
gateway panel**, not the phone (ARCHITECTURE.md §8).

### iOS
- Already set in `ios/Runner/Info.plist`: `NSAllowsLocalNetworking` and
  `NSLocalNetworkUsageDescription` (LAN hub, see above).
- `ios/Runner/Info.plist`: enable background modes (remote notifications).
- **Critical alerts** (break through silent/DND) require Apple's
  *Critical Alerts entitlement* (request from Apple). Once granted, enable
  `requestCriticalPermission` in `notifications.dart` and add the entitlement.

### Remote push (FCM) — optional
Off by default. To enable:
1. Create a Firebase project; add `google-services.json` (Android) and
   `GoogleService-Info.plist` (iOS) via `flutterfire configure`.
2. Run with `--dart-define=CANARY_FCM=true`.

Without FCM the app is fully functional via WebSocket (foreground) + local
notifications; FCM adds reliable background/remote delivery.

## Checks

```bash
flutter analyze        # expect: No issues found!
flutter test           # widget smoke test + BuildingSummary parsing against the HARDWARE.md contract
bash ../scripts/mobile_check.sh   # pub get + analyze in one go (exit 0 = clean)
```

Troubleshooting: [`../DEBUG.md`](../DEBUG.md) §4.

## Notes / not yet built
- Sign-in is the hub's username-only dev token over plain HTTP: trusted LAN/VLAN only
  ([`../RUNME.md`](../RUNME.md) §1.10).
- Device-token registration to the backend (a `/devices` endpoint is a later phase).
- Indoor positioning (MVP uses pre-mapped per-floor routes + static fallback).
- Offline queue uses `shared_preferences`; swap to Hive/Isar for scale.

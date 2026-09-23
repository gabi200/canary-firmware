# Canary — Resident App (Flutter)

Cross-platform (Android + iOS) resident app for the Canary safety platform:
emergency alerts, **evacuation guidance routed away from the hazard**, and an
**"I'm safe" check-in** that feeds backend victim-accounting.

Implements ARCHITECTURE.md **section D** (Flutter, FCM + local notifications,
critical alerts, offline check-in queue, presence consent).

## Architecture

```
lib/
  main.dart                  app entry (init storage + notifications, ProviderScope)
  src/
    config.dart              API/WS base, building id, FCM flag (--dart-define overridable)
    theme.dart               hazard color language (normal/warning/alarm/evacuation)
    models/                  auth, incident, evacuation, check_in
    services/
      api_client.dart        REST (dio): login, incidents, evacuation, checkin
      ws_client.dart         live incident stream (web_socket_channel) + auto-reconnect
      storage.dart           shared_preferences: session, consent, offline check-in queue
      notifications.dart     flutter_local_notifications (+ optional FCM)
      firebase_push.dart     isolated FCM init (critical-alert permission)
    state/                   Riverpod: session, incidents (+WS), evacuation, consent
    ui/                      onboarding, home, alarm (full-screen), settings, widgets/
```

**State management:** Riverpod (`flutter_riverpod`). The incident controller merges
the REST snapshot with the live WebSocket stream, raises a heads-up notification on
entering an alarming state, and flushes the offline check-in queue on reconnect.

## Run (against the local backend)

The platform folders (`android/`, `ios/`) are not committed. Generate them once,
then run:

```bash
cd mobile
flutter create .            # backfills android/ ios/ (keeps lib/ + pubspec.yaml)
flutter pub get

# start the backend first (repo root): docker compose up -d
# Android emulator reaches the host at 10.0.2.2 (the default).
flutter run

# physical device / different host:
flutter run --dart-define=CANARY_API=http://<your-host-ip>:8000
```

Log in as **`ana`** (seeded resident), building **`bld_007`**. Then trigger a hazard:

```bash
docker compose run --rm simulator --scenario gas_leak
```

The app receives the WebSocket `incident` event → raises a notification →
auto-opens the full-screen alarm → shows evacuation route + assembly point →
tap **"I'm safe / evacuated"** → backend unaccounted count drops.

## Platform configuration (required for real device features)

### Android — `android/app/src/main/AndroidManifest.xml`
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

## Notes / not yet built
- Device-token registration to the backend (a `/devices` endpoint is a later phase).
- Indoor positioning (MVP uses pre-mapped per-floor routes + static fallback).
- Offline queue uses `shared_preferences`; swap to Hive/Isar for scale.

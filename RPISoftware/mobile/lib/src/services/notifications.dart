import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../config.dart';
import '../../l10n/gen/app_localizations.dart';
import 'firebase_push.dart';

/// Local + (optional) remote notifications.
///
/// Local notifications work with no Firebase setup and cover the demo path (an
/// alarm arriving over WebSocket raises a heads-up notification). Remote FCM push
/// is wired behind Config.enableFirebasePush and requires a Firebase project +
/// the iOS critical-alert entitlement to break through silent/DND (see README).
class Notifications {
  Notifications._();
  static final Notifications instance = Notifications._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// High-importance channel for life-safety alerts (Android).
  late final AndroidNotificationChannel _alarmChannel;

  AppLocalizations get _l10n {
    final locale = PlatformDispatcher.instance.locale;
    return lookupAppLocalizations(locale.languageCode == 'en' ? const Locale('en') : const Locale('ro'));
  }

  Future<void> init() async {
    if (_ready) return;
    final l10n = _l10n;
    _alarmChannel = AndroidNotificationChannel(
      'canary_alarm',
      l10n.notificationChannelName,
      description: l10n.notificationChannelDescription,
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      // requestCriticalPermission: true,  // enable once the entitlement is approved
    );
    await _plugin.initialize(const InitializationSettings(android: android, iOS: ios));

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_alarmChannel);

    if (Config.enableFirebasePush) {
      await _initFirebase();
    }
    _ready = true;
  }

  Future<void> showAlarm(String title, String body, {bool critical = false}) async {
    final android = AndroidNotificationDetails(
      _alarmChannel.id,
      _alarmChannel.name,
      channelDescription: _alarmChannel.description,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: critical,
      visibility: NotificationVisibility.public,
    );
    final ios = DarwinNotificationDetails(
      interruptionLevel: critical ? InterruptionLevel.critical : InterruptionLevel.timeSensitive,
      presentSound: true,
    );
    await _plugin.show(
      title.hashCode,
      title,
      body,
      NotificationDetails(android: android, iOS: ios),
    );
  }

  /// Guarded FCM setup. Imported lazily so the app builds/runs without Firebase
  /// configured; any failure (missing config) degrades to WebSocket + local only.
  Future<void> _initFirebase() async {
    try {
      // Lazy imports kept local so a missing Firebase config never breaks startup.
      // ignore: avoid_dynamic_calls
      await _firebaseSetup();
    } catch (e) {
      debugPrint('Canary: FCM disabled ($e); using WebSocket + local notifications only.');
    }
  }

  Future<void> _firebaseSetup() async {
    // Implemented in firebase_push.dart to keep firebase imports isolated.
    await firebaseInitAndSubscribe(onMessage: (title, body) => showAlarm(title, body, critical: true));
  }
}

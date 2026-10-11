import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/app_localizations.dart';
import '../config.dart';
import 'firebase_push.dart';

/// Local + (optional) remote notifications.
///
/// Local notifications work with no Firebase setup and cover the demo path (an
/// alarm arriving over WebSocket raises a heads-up notification). Remote FCM push
/// is wired behind Config.enableFirebasePush and requires a Firebase project +
/// the iOS critical-alert entitlement to break through silent/DND (see README).
/// Channel name/description and fallback titles follow the app language.
class Notifications {
  Notifications._();
  static final Notifications instance = Notifications._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  AppLocalizations _l10n = lookupAppLocalizations(const Locale('en'));

  /// High-importance channel for life-safety alerts (Android), named in the app language.
  AndroidNotificationChannel get _alarmChannel => AndroidNotificationChannel(
        'canary_alarm',
        _l10n.notificationChannelName,
        description: _l10n.notificationChannelDescription,
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );

  Future<void> init(AppLocalizations l10n) async {
    _l10n = l10n;
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      // requestCriticalPermission: true,  // enable once the entitlement is approved
    );
    await _plugin.initialize(const InitializationSettings(android: android, iOS: ios));
    await _registerChannel();

    if (Config.enableFirebasePush) {
      await _initFirebase();
    }
    _ready = true;
  }

  /// Language switch: later notifications (and the Android channel name shown in
  /// system settings) use the new language.
  Future<void> setLocalizations(AppLocalizations l10n) async {
    _l10n = l10n;
    if (_ready) await _registerChannel();
  }

  // Re-creating an existing channel id only updates its name and description.
  Future<void> _registerChannel() async {
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_alarmChannel);
  }

  Future<void> showAlarm(String title, String body, {bool critical = false}) async {
    final channel = _alarmChannel;
    final android = AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
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
    await firebaseInitAndSubscribe(
      onMessage: (title, body) =>
          showAlarm(title ?? _l10n.pushFallbackTitle, body ?? '', critical: true),
    );
  }
}

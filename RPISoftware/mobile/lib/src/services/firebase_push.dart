import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../../l10n/gen/app_localizations.dart';

typedef PushHandler = void Function(String title, String body);

/// Background message handler must be a top-level / static function.
@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // The OS renders the notification payload; data-only messages would be handled here.
}

/// Initialize Firebase, request (critical) push permission, and forward foreground
/// messages. Only called when Config.enableFirebasePush is true AND Firebase is
/// configured for the platform; otherwise the caller's try/catch degrades cleanly.
Future<void> firebaseInitAndSubscribe({required PushHandler onMessage}) async {
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_bgHandler);

  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
    criticalAlert: true, // requires the iOS critical-alert entitlement to take effect
  );

  final token = await messaging.getToken();
  // A later phase POSTs this token to the backend so notifications can target the device.
  debugPrint('Canary FCM token: $token');

  FirebaseMessaging.onMessage.listen((m) {
    final locale = PlatformDispatcher.instance.locale;
    final l10n = lookupAppLocalizations(locale.languageCode == 'en' ? const Locale('en') : const Locale('ro'));
    onMessage(l10n.alertNotificationTitle(l10n.appTitle), l10n.openAppForGuidance);
  });
}

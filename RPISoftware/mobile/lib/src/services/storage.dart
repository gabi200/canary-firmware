import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/auth.dart';
import '../models/check_in.dart';

/// Local persistence: auth session, presence-consent flag, and the offline
/// check-in queue. SharedPreferences keeps the MVP dependency-light; a later
/// phase swaps the queue for Hive/Isar as called out in ARCHITECTURE.md section D.
class Storage {
  Storage(this._prefs);
  final SharedPreferences _prefs;

  static const _kSession = 'session';
  static const _kConsent = 'presence_consent';
  static const _kQueue = 'pending_checkins';

  static Future<Storage> create() async => Storage(await SharedPreferences.getInstance());

  // --- session ---
  Future<void> saveSession(AuthSession s) =>
      _prefs.setString(_kSession, jsonEncode(s.toJson()));

  AuthSession? loadSession() {
    final raw = _prefs.getString(_kSession);
    if (raw == null) return null;
    try {
      return AuthSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearSession() => _prefs.remove(_kSession);

  // --- consent ---
  bool get presenceConsent => _prefs.getBool(_kConsent) ?? false;
  Future<void> setPresenceConsent(bool v) => _prefs.setBool(_kConsent, v);

  // --- offline check-in queue ---
  List<PendingCheckIn> pendingCheckIns() {
    final raw = _prefs.getStringList(_kQueue) ?? const [];
    return raw
        .map((e) => PendingCheckIn.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();
  }

  Future<void> enqueueCheckIn(PendingCheckIn p) async {
    final list = _prefs.getStringList(_kQueue) ?? <String>[];
    list.add(jsonEncode(p.toJson()));
    await _prefs.setStringList(_kQueue, list);
  }

  Future<void> clearQueue() => _prefs.remove(_kQueue);

  Future<void> replaceQueue(List<PendingCheckIn> items) =>
      _prefs.setStringList(_kQueue, items.map((e) => jsonEncode(e.toJson())).toList());
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/auth.dart';
import '../models/check_in.dart';

/// Local persistence: auth session, presence-consent flag, app language, and the
/// offline check-in queue. SharedPreferences keeps the MVP dependency-light; a later
/// phase swaps the queue for Hive/Isar as called out in ARCHITECTURE.md section D.
class Storage {
  Storage(this._prefs);
  final SharedPreferences _prefs;

  static const _kSession = 'session';
  static const _kConsent = 'presence_consent';
  static const _kQueue = 'pending_checkins';
  static const _kLanguage = 'language';
  static const _kCareHintDismissed = 'care_hint_dismissed';
  static const _kHomeView = 'home_status_view';
  static const _kSensorScope = 'sensor_scope';
  static const _kIncidentLocation = 'incident_location';
  static const _kThemeMode = 'theme_mode';
  static const _kSectionsCollapsed = 'home_sections_collapsed';
  static const _kRoomsExpanded = 'home_rooms_expanded';

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

  // --- language ('ro' | 'en'); null until the user picks one ---
  String? get languageCode => _prefs.getString(_kLanguage);
  Future<void> setLanguageCode(String code) => _prefs.setString(_kLanguage, code);

  // --- home hint for emergency profiles. Only this flag is stored: care
  // profiles themselves (health data) are never written to the device. ---
  bool get careHintDismissed => _prefs.getBool(_kCareHintDismissed) ?? false;
  Future<void> setCareHintDismissed() => _prefs.setBool(_kCareHintDismissed, true);

  // --- "Starea locuinței" view: 'list' (default) | 'sketch' ---
  String get homeStatusView => _prefs.getString(_kHomeView) ?? 'list';
  Future<void> setHomeStatusView(String view) => _prefs.setString(_kHomeView, view);

  // --- appearance: 'system' | 'light' | 'dark'; null until the user picks ---
  String? get themeMode => _prefs.getString(_kThemeMode);
  Future<void> setThemeMode(String mode) => _prefs.setString(_kThemeMode, mode);

  // --- home list: collapsed sections and rooms opened inline (ids only) ---
  List<String> get sectionsCollapsed => _prefs.getStringList(_kSectionsCollapsed) ?? const [];
  Future<void> setSectionsCollapsed(List<String> ids) => _prefs.setStringList(_kSectionsCollapsed, ids);
  List<String> get roomsExpanded => _prefs.getStringList(_kRoomsExpanded) ?? const [];
  Future<void> setRoomsExpanded(List<String> ids) => _prefs.setStringList(_kRoomsExpanded, ids);

  // --- apartment / room picked over the sensor lists: JSON with the building
  // and unit / zone ids only ---
  String? get sensorScope => _prefs.getString(_kSensorScope);
  Future<void> setSensorScope(String json) => _prefs.setString(_kSensorScope, json);

  // --- "Unde ești acum?" per account and incident: {"<user>/<incident>": home |
  // building | outside}, the most recent ones only ---
  static const _incidentLocationsKept = 20;

  Map<String, String> _incidentLocations() {
    try {
      final j = jsonDecode(_prefs.getString(_kIncidentLocation) ?? '{}');
      return j is Map ? {for (final e in j.entries) if (e.value is String) '${e.key}': e.value as String} : {};
    } catch (_) {
      return {};
    }
  }

  String? incidentLocation(String key) => _incidentLocations()[key];

  Future<void> setIncidentLocation(String key, String location) {
    final all = _incidentLocations()
      ..remove(key)
      ..[key] = location;
    final kept = all.entries.skip(all.length > _incidentLocationsKept ? all.length - _incidentLocationsKept : 0);
    return _prefs.setString(_kIncidentLocation, jsonEncode(Map.fromEntries(kept)));
  }

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

import 'package:dio/dio.dart';

import '../config.dart';
import '../models/auth.dart';
import '../models/care_profile.dart';
import '../models/check_in.dart';
import '../models/dashboard.dart';
import '../models/evacuation.dart';
import '../models/history.dart';
import '../models/household.dart';
import '../models/incident.dart';
import '../models/me.dart';
import '../models/node_command.dart';
import '../models/zone_info.dart';
import '../models/summary.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.detail, this.fieldErrors = const {}});
  final String message;

  /// null when no HTTP response arrived (server unreachable, timeout).
  final int? statusCode;

  /// The server's own `detail` text, if it sent one.
  final String? detail;

  /// Validation messages by request field (e.g. 'phone'), from a 422.
  final Map<String, String> fieldErrors;
  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin REST client over the Canary backend. Holds the bearer token and injects
/// it on every request once a session exists, plus `Accept-Language` (ro | en)
/// from [languageCode] so the hub's analysis text comes back in the app language.
class ApiClient {
  ApiClient({Dio? dio, String Function()? languageCode})
      : _languageCode = languageCode,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: Config.apiOverride,
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 8),
            )) {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (_token != null) {
        options.headers['Authorization'] = 'Bearer $_token';
      }
      // Read per request, so a language switch applies to the very next call.
      final lang = _languageCode?.call();
      if (lang != null) {
        options.headers['Accept-Language'] = lang;
      }
      handler.next(options);
    }, onResponse: (response, handler) {
      _failuresWithoutResponse = 0;
      handler.next(response);
    }, onError: (e, handler) {
      if (e.response == null) {
        // No answer at all: the hub moved (new hotspot, failover). From the second in a row on,
        // every failure asks for a search (the hub controller runs one at a time), so a search
        // that found nothing (Pis still rebooting) is followed by another.
        if (++_failuresWithoutResponse >= 2) onUnreachable?.call();
      } else {
        _failuresWithoutResponse = 0;
      }
      // The hub rejected the token (expired after 8 h, or a new hub key): sign out.
      if (e.response?.statusCode == 401 && e.requestOptions.headers['Authorization'] != null) {
        onUnauthorized?.call();
      }
      handler.next(e);
    }));
  }

  final Dio _dio;
  final String Function()? _languageCode;
  String? _token;
  int _failuresWithoutResponse = 0;

  /// Called when an authenticated request gets 401 (set by the session owner).
  void Function()? onUnauthorized;

  /// Called on every request, from the second in a row, that got no HTTP response (set by
  /// the hub controller, which ignores calls while a search runs).
  void Function()? onUnreachable;

  /// The hub's REST base, e.g. http://10.247.177.188:8000; set by the hub locator.
  String get baseUrl => _dio.options.baseUrl;
  set baseUrl(String url) {
    _dio.options.baseUrl = url;
    _failuresWithoutResponse = 0;
  }

  void setToken(String? token) => _token = token;

  Future<AuthSession> login(String username, String buildingId) async {
    try {
      final res = await _dio.post('/api/v1/auth/token', data: {'username': username});
      final data = res.data as Map<String, dynamic>;
      _token = data['access_token'] as String;
      return AuthSession(
        token: data['access_token'] as String,
        userId: data['user_id'] as String,
        role: data['role'] as String,
        username: username,
        buildingId: buildingId,
      );
    } on DioException catch (e) {
      throw _wrap(e, 'Login failed');
    }
  }

  Future<List<Incident>> activeIncidents(String buildingId) async {
    try {
      final res = await _dio.get(
        '/api/v1/buildings/$buildingId/incidents',
        queryParameters: {'active': true},
      );
      return (res.data as List)
          .map((e) => Incident.fromJson(e as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load incidents');
    }
  }

  Future<EvacuationInfo> evacuation(String buildingId) async {
    try {
      final res = await _dio.get('/api/v1/buildings/$buildingId/evacuation');
      return EvacuationInfo.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load evacuation routes');
    }
  }

  /// Hub analysis of the building's sensors (HARDWARE.md §4). Analysis only, no
  /// raw measurements; any authenticated role (residents included) may read it.
  Future<BuildingSummary> summary(String buildingId) async {
    try {
      final res = await _dio.get('/api/v1/buildings/$buildingId/summary');
      final data = res.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected sensor status response', statusCode: res.statusCode);
      }
      return BuildingSummary.fromJson(data);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load sensor status');
    }
  }

  /// A node's measurements over the last [minutes] (1–10080), oldest first.
  /// Residents may read only their own / common zones' nodes and an allow-list
  /// of [fields] (≤ 20).
  Future<NodeHistory> nodeHistory(String nodeId, {required int minutes, required List<String> fields}) async {
    try {
      final res = await _dio.get(
        '/api/v1/nodes/${Uri.encodeComponent(nodeId)}/history',
        queryParameters: {'minutes': minutes, 'fields': fields.join(',')},
      );
      final data = res.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected history response', statusCode: res.statusCode);
      }
      return NodeHistory.fromJson(data);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load sensor history');
    }
  }

  /// Sends a device command (HARDWARE.md §4). 202 → the hub's record, status
  /// `sent`; the device's answer follows as a WebSocket `command_result`.
  /// 422 wrong command for the kind, 409 offline, 429 within 3 s of the last
  /// one, 404 not the caller's sensor, 403 role may not command, 503 the hub's
  /// MQTT broker is down.
  Future<NodeCommand> sendNodeCommand(String nodeId, NodeCommandType command) async {
    try {
      final res = await _dio.post(
        '/api/v1/nodes/${Uri.encodeComponent(nodeId)}/commands',
        data: {'command': command.wire},
      );
      final cmd = NodeCommand.tryParse(res.data);
      if (cmd == null) {
        throw ApiException('Unexpected command response', statusCode: res.statusCode);
      }
      return cmd;
    } on DioException catch (e) {
      throw _wrap(e, 'Could not send the command');
    }
  }

  /// A node's latest commands, newest first (the poll fallback for results).
  Future<List<NodeCommand>> nodeCommands(String nodeId, {int limit = 20}) async {
    try {
      final res = await _dio.get(
        '/api/v1/nodes/${Uri.encodeComponent(nodeId)}/commands',
        queryParameters: {'limit': limit},
      );
      final data = res.data;
      return [
        if (data is List)
          for (final item in data)
            if (NodeCommand.tryParse(item) case final NodeCommand c) c,
      ];
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load commands');
    }
  }

  Future<void> checkIn(String incidentId, CheckInStatus status) async {
    try {
      await _dio.post(
        '/api/v1/incidents/$incidentId/checkin',
        data: {'status': status.token},
      );
    } on DioException catch (e) {
      throw _wrap(e, 'Check-in failed');
    }
  }

  /// "Unde ești acum?" for an incident (residents only); the latest answer wins.
  /// 422 for an unknown value, 404 when the incident isn't in their building.
  Future<void> reportLocation(String incidentId, ResidentLocation location) async {
    try {
      await _dio.post(
        '/api/v1/incidents/$incidentId/location',
        data: {'location': location.token},
      );
    } on DioException catch (e) {
      throw _wrap(e, 'Could not send your location');
    }
  }

  // --- manager / dispatcher dashboard ------------------------------------
  Future<Accounting> accounting(String incidentId) async {
    try {
      final res = await _dio.get('/api/v1/incidents/$incidentId/accounting');
      return Accounting.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load accounting');
    }
  }

  Future<Roster> roster(String incidentId) async {
    try {
      final res = await _dio.get('/api/v1/incidents/$incidentId/roster');
      return Roster.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load resident roster');
    }
  }

  /// id -> human zone label (e.g. "zone_kitchen" -> "Bucătărie").
  Future<Map<String, String>> zoneLabels(String buildingId) async {
    try {
      final res = await _dio.get('/api/v1/buildings/$buildingId/zones');
      final map = <String, String>{};
      for (final z in res.data as List) {
        final m = z as Map<String, dynamic>;
        map[m['id'] as String] = (m['label'] as String?)?.isNotEmpty == true
            ? m['label'] as String
            : m['id'] as String;
      }
      return map;
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load zones');
    }
  }

  /// The building's zones with their position (metres) and unit, for the home
  /// sketch.
  Future<List<ZoneInfo>> zones(String buildingId) async {
    try {
      final res = await _dio.get('/api/v1/buildings/$buildingId/zones');
      return [
        for (final z in (res.data as List).whereType<Map<String, dynamic>>())
          if (z['id'] is String) ZoneInfo.fromJson(z),
      ];
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load zones');
    }
  }

  /// zone id -> unit id (residents may read the building's zones).
  Future<Map<String, String>> zoneUnits(String buildingId) async {
    try {
      final res = await _dio.get('/api/v1/buildings/$buildingId/zones');
      return {
        for (final z in (res.data as List).whereType<Map<String, dynamic>>())
          if (z['id'] is String && z['unit_id'] is String) z['id'] as String: z['unit_id'] as String,
      };
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load zones');
    }
  }

  /// The signed-in account (`GET /me`), or null on a hub that doesn't have the
  /// endpoint yet (404 / 405).
  Future<MeProfile?> me() async {
    try {
      final res = await _dio.get('/api/v1/me');
      final data = res.data;
      return data is Map<String, dynamic> ? MeProfile.fromJson(data) : null;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404 || code == 405) return null;
      throw _wrap(e, 'Could not load your account');
    }
  }

  /// `PATCH /me` with only the changed fields; 422 carries a per-field message.
  Future<MeProfile> updateMe(Map<String, String> changes) async {
    try {
      final res = await _dio.patch('/api/v1/me', data: changes);
      return MeProfile.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not save your account');
    }
  }

  // --- care profiles ("Profil de urgență"): health data, kept in memory only ---
  Future<List<CareProfile>> careProfiles() async {
    try {
      final res = await _dio.get('/api/v1/me/care-profiles');
      return (res.data as List).whereType<Map<String, dynamic>>().map(CareProfile.fromJson).toList();
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load care profiles');
    }
  }

  Future<CareProfile> createCareProfile(CareProfileDraft draft) async {
    try {
      final res = await _dio.post('/api/v1/me/care-profiles', data: draft.toJson());
      return CareProfile.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not save the care profile');
    }
  }

  Future<CareProfile> updateCareProfile(String id, CareProfileDraft draft) async {
    try {
      final res = await _dio.put('/api/v1/me/care-profiles/${Uri.encodeComponent(id)}', data: draft.toJson());
      return CareProfile.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not save the care profile');
    }
  }

  Future<void> deleteCareProfile(String id) async {
    try {
      await _dio.delete('/api/v1/me/care-profiles/${Uri.encodeComponent(id)}');
    } on DioException catch (e) {
      throw _wrap(e, 'Could not delete the care profile');
    }
  }

  /// Check-in on behalf of a household member during an incident.
  Future<void> careCheckIn(String incidentId, String careProfileId, CheckInStatus status) async {
    try {
      await _dio.post(
        '/api/v1/incidents/$incidentId/care-checkin',
        data: {'care_profile_id': careProfileId, 'status': status.token},
      );
    } on DioException catch (e) {
      throw _wrap(e, 'Care check-in failed');
    }
  }

  // --- household invites ---
  Future<CreatedInvite> createInvite({required String unitId, String? careProfileId}) async {
    try {
      final res = await _dio.post('/api/v1/me/household/invites',
          data: {'unit_id': unitId, 'care_profile_id': careProfileId});
      return CreatedInvite.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not create the invite');
    }
  }

  Future<List<PendingInvite>> pendingInvites() async {
    try {
      final res = await _dio.get('/api/v1/me/household/invites');
      return (res.data as List).whereType<Map<String, dynamic>>().map(PendingInvite.fromJson).toList();
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load invites');
    }
  }

  Future<void> revokeInvite(String id) async {
    try {
      await _dio.delete('/api/v1/me/household/invites/${Uri.encodeComponent(id)}');
    } on DioException catch (e) {
      throw _wrap(e, 'Could not revoke the invite');
    }
  }

  Future<InvitePreview> invitePreview(String code) async {
    try {
      final res = await _dio.get('/api/v1/household/invites/${Uri.encodeComponent(code)}');
      return InvitePreview.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load the invite');
    }
  }

  Future<AcceptedInvite> acceptInvite(String code, {required bool takeOverCareProfile, required bool consent}) async {
    try {
      final res = await _dio.post('/api/v1/household/invites/${Uri.encodeComponent(code)}/accept',
          data: {'take_over_care_profile': takeOverCareProfile, 'consent': consent});
      return AcceptedInvite.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e, 'Could not accept the invite');
    }
  }

  Future<List<HouseholdUnit>> household() async {
    try {
      final res = await _dio.get('/api/v1/me/household');
      return (res.data as List).whereType<Map<String, dynamic>>().map(HouseholdUnit.fromJson).toList();
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load the household');
    }
  }

  Future<void> leaveUnit(String unitId) async {
    try {
      await _dio.delete('/api/v1/me/household/${Uri.encodeComponent(unitId)}');
    } on DioException catch (e) {
      throw _wrap(e, 'Could not leave the apartment');
    }
  }

  /// Manager/dispatcher action: dismiss | order-evacuation | resolve.
  Future<void> incidentAction(String incidentId, String action) async {
    try {
      await _dio.post('/api/v1/incidents/$incidentId/$action');
    } on DioException catch (e) {
      throw _wrap(e, 'Action failed');
    }
  }

  ApiException _wrap(DioException e, String fallback) {
    final code = e.response?.statusCode;
    final body = e.response?.data;
    final (detail, fields) = parseErrorDetail(body is Map ? body['detail'] : null);
    return ApiException(detail ?? e.message ?? fallback, statusCode: code, detail: detail, fieldErrors: fields);
  }
}

/// FastAPI error `detail`: a string, `{"field"|"loc", "msg"|"message"}`, or a
/// list of validation errors with `loc` — as (message, messages by field).
(String?, Map<String, String>) parseErrorDetail(Object? detail) {
  if (detail is String) return (detail.isEmpty ? null : detail, const {});
  final entries = detail is List ? detail : [if (detail is Map) detail];
  final fields = <String, String>{};
  final messages = <String>[];
  for (final entry in entries.whereType<Map>()) {
    final msg = entry['msg'] ?? entry['message'];
    if (msg is! String || msg.isEmpty) continue;
    messages.add(msg);
    final loc = entry['loc'];
    final field = entry['field'] is String
        ? entry['field'] as String
        : loc is List && loc.isNotEmpty && loc.last is String
            ? loc.last as String
            : null;
    if (field != null && field != 'body') fields.putIfAbsent(field, () => msg);
  }
  return (messages.isEmpty ? null : messages.join('\n'), fields);
}

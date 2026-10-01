import 'package:dio/dio.dart';

import '../config.dart';
import '../models/auth.dart';
import '../models/check_in.dart';
import '../models/dashboard.dart';
import '../models/evacuation.dart';
import '../models/incident.dart';
import '../models/summary.dart';
import '../models/zone.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin REST client over the Canary backend. Holds the bearer token and injects
/// it on every request once a session exists.
class ApiClient {
  ApiClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: Config.apiBase,
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 8),
            )) {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (_token != null) {
        options.headers['Authorization'] = 'Bearer $_token';
      }
      handler.next(options);
    }));
  }

  final Dio _dio;
  String? _token;

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
    return EvacuationInfo.fromJson(await evacuationJson(buildingId));
  }

  Future<Map<String, dynamic>> evacuationJson(String buildingId) async {
    try {
      final res = await _dio.get('/api/v1/buildings/$buildingId/evacuation');
      final data = res.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException('Unexpected evacuation route response', statusCode: res.statusCode);
      }
      return data;
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
  /// Zones with their schematic positions (`pos_x`/`pos_y`), for the floor-plan view.
  Future<List<ZoneInfo>> zones(String buildingId) async {
    try {
      final res = await _dio.get('/api/v1/buildings/$buildingId/zones');
      final data = res.data;
      if (data is! List) {
        throw ApiException('Unexpected zones response', statusCode: res.statusCode);
      }
      return [
        for (final entry in data)
          if (entry is Map<String, dynamic>) ZoneInfo.fromJson(entry),
      ];
    } on DioException catch (e) {
      throw _wrap(e, 'Could not load zones');
    }
  }

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
    final detail = e.response?.data is Map ? (e.response?.data['detail']?.toString()) : null;
    return ApiException(detail ?? e.message ?? fallback, statusCode: code);
  }
}

import 'dart:typed_data';

import 'package:canary_resident/src/models/auth.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/session_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A hub that rejects every token, like after the 8 h expiry.
class _Rejecting implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromString('{"detail":"invalid token"}', 401, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
}

void main() {
  test('an expired token signs out instead of looking like an unreachable hub', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = Storage(await SharedPreferences.getInstance());
    await storage.saveSession(const AuthSession(
        token: 'old', userId: 'usr_ana', role: 'resident', username: 'ana', buildingId: 'bld_007'));
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://hub'))..httpClientAdapter = _Rejecting());
    final session = SessionController(storage, api);
    expect(session.state, isNotNull);

    await expectLater(api.summary('bld_007'), throwsA(isA<ApiException>()));
    await Future<void>.delayed(Duration.zero);

    expect(session.state, isNull);
    expect(storage.loadSession(), isNull);
  });
}

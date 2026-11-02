import 'dart:convert';
import 'dart:io';

import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/hub_locator.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// A probe that answers true only for [hubs] and records every URL it was asked about.
class FakeProbe {
  FakeProbe(this.hubs, {this.delay = Duration.zero});
  final Set<String> hubs;
  final Duration delay;
  final asked = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;

  Future<bool> call(String url) async {
    asked.add(url);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    await Future<void>.delayed(delay);
    inFlight--;
    return hubs.contains(url);
  }
}

HubLocator locator(
  FakeProbe probe, {
  List<String> browsed = const [],
  String? wifi = '10.247.177.50',
  String override = '',
  String? saved,
  void Function()? onBrowse,
}) =>
    HubLocator(
      probe: probe.call,
      browse: (_) async {
        onBrowse?.call();
        return browsed;
      },
      wifiIp: () async => wifi,
      override: override,
      saved: saved,
    );

void main() {
  const hub = 'http://10.247.177.188:8000';

  test('uses the override first, when it answers', () async {
    var browsed = false;
    final probe = FakeProbe({'http://dev:8000'});
    final url = await locator(probe, override: 'http://dev:8000', onBrowse: () => browsed = true).locate();
    expect(url, 'http://dev:8000');
    expect(browsed, isFalse);
  });

  test('a dead override falls through to discovery', () async {
    final url = await locator(FakeProbe({hub}), override: 'http://old:8000', browsed: [hub]).locate();
    expect(url, hub);
  });

  test('saved address answers -> no browse', () async {
    var browsed = false;
    final url = await locator(FakeProbe({hub}), saved: hub, onBrowse: () => browsed = true).locate();
    expect(url, hub);
    expect(browsed, isFalse);
  });

  test('browse result that answers wins over the scan', () async {
    final probe = FakeProbe({hub, 'http://10.247.177.2:8000'});
    final url = await locator(probe, browsed: [hub]).locate();
    expect(url, hub);
    expect(probe.asked, [hub]);
  });

  test('falls back to scanning the /24', () async {
    final probe = FakeProbe({hub});
    final url = await locator(probe).locate();
    expect(url, hub);
    expect(probe.asked, isNot(contains('http://10.247.177.50:8000')));
  });

  test('returns null when nothing answers', () async {
    final probe = FakeProbe({});
    expect(await locator(probe).locate(), isNull);
    expect(probe.asked.length, 253);
  });

  test('returns null without a Wi-Fi address and no other candidates', () async {
    expect(await locator(FakeProbe({}), wifi: null).locate(), isNull);
  });

  test('scan keeps at most 30 probes in flight', () async {
    final probe = FakeProbe({}, delay: const Duration(milliseconds: 2));
    await locator(probe).locate();
    expect(probe.maxInFlight, lessThanOrEqualTo(30));
    expect(probe.maxInFlight, greaterThan(1));
  });

  group('default probe', () {
    late HttpServer server;
    late String body;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response
          ..headers.contentType = ContentType.json
          ..write(body)
          ..close();
      });
    });
    tearDown(() => server.close(force: true));

    test('rejects a responder that is not canary-backend', () async {
      final url = 'http://127.0.0.1:${server.port}';
      body = jsonEncode({'status': 'ok', 'service': 'other'});
      expect(await probeHub(url), isFalse);
      body = jsonEncode({'status': 'ok', 'service': 'canary-backend'});
      expect(await probeHub(url), isTrue);
      body = 'not json';
      expect(await probeHub(url), isFalse);
    });

    test('an unreachable address is not a hub', () async {
      expect(await probeHub('http://127.0.0.1:1'), isFalse);
    });
  });

  group('ApiClient unreachable detection', () {
    ApiClient client(List<int?> outcomes) {
      final dio = Dio(BaseOptions(baseUrl: 'http://hub'));
      var i = 0;
      dio.httpClientAdapter = _ScriptedAdapter(() => outcomes[i++]);
      return ApiClient(dio: dio);
    }

    test('two failures with no response fire onUnreachable once', () async {
      final api = client([null, null, null]);
      var fired = 0;
      api.onUnreachable = () => fired++;
      for (var n = 0; n < 3; n++) {
        await expectLater(api.activeIncidents('b'), throwsA(isA<ApiException>()));
      }
      expect(fired, 1);
    });

    test('an HTTP response in between resets the count', () async {
      final api = client([null, 500, null]);
      var fired = 0;
      api.onUnreachable = () => fired++;
      for (var n = 0; n < 3; n++) {
        await expectLater(api.activeIncidents('b'), throwsA(isA<ApiException>()));
      }
      expect(fired, 0);
    });

    test('baseUrl can be changed at runtime', () {
      final api = client([]);
      api.baseUrl = hub;
      expect(api.baseUrl, hub);
    });
  });
}

/// Answers each request with the next scripted outcome: a status code, or null for
/// "no response" (connection error).
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.next);
  final int? Function() next;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    final code = next();
    if (code == null) {
      throw DioException.connectionError(requestOptions: options, reason: 'unreachable');
    }
    return ResponseBody.fromString('{}', code, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

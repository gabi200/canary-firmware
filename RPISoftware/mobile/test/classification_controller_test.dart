import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:canary_resident/src/models/incident.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

class _Api extends ApiClient {
  _Api(String url) : super(dio: Dio(BaseOptions(baseUrl: url)));
  int calls = 0;
  Completer<List<Incident>>? pending;
  List<Incident> snapshot = [_incident('steam')];
  @override
  Future<List<Incident>> activeIncidents(String buildingId) async {
    calls++;
    return pending == null ? snapshot : pending!.future;
  }
}

Incident _incident(String label) => Incident.fromJson({
      'id': 'i',
      'building_id': 'bld',
      'state': 'detection',
      'signature': {'label': label, 'confidence': 0.8},
    });

void main() {
  test(
      'polls classifications, coalesces requests, preserves WS metadata and rejects stale snapshots',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final connected = Completer<WebSocket>();
    server.listen((request) async {
      connected.complete(await WebSocketTransformer.upgrade(request));
    });
    final storage = await signedInStorage();
    final api = _Api('http://127.0.0.1:${server.port}');
    final controller = IncidentController(api, storage, storage.loadSession());
    final socket = await connected.future.timeout(const Duration(seconds: 3));
    addTearDown(() async {
      controller.dispose();
      await socket.close();
      await server.close(force: true);
    });
    expect(controller.state.incidents.single.signature?.label, 'steam');
    api.snapshot = [_incident('cooking')];
    await Future<void>.delayed(const Duration(milliseconds: 10200));
    expect(controller.state.incidents.single.signature?.label, 'cooking');

    api.pending = Completer<List<Incident>>();
    final first = controller.refresh();
    final second = controller.refresh();
    final calls = api.calls;
    socket.add(jsonEncode({
      'type': 'incident',
      'incident_id': 'i',
      'building_id': 'bld',
      'state': 'verification',
      'severity': 'warning',
      'ts': '2026-11-04T12:00:00Z'
    }));
    await controller.liveEvents.first;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.state.incidents.single.signature?.label, 'cooking');
    api.pending!.complete([_incident('aerosol')]);
    await Future.wait([first, second]);
    expect(api.calls, calls);
    expect(controller.state.incidents.single.state, 'verification');
    expect(controller.state.incidents.single.signature?.label, 'cooking');
  });

  test('disposed refresh cannot write or open a socket', () async {
    final storage = await signedInStorage();
    final api = _Api('http://127.0.0.1:1')
      ..pending = Completer<List<Incident>>();
    final controller = IncidentController(api, storage, storage.loadSession());
    controller.dispose();
    api.pending!.complete([_incident('steam')]);
    await Future<void>.delayed(Duration.zero);
    expect(api.calls, 1);
  });
}

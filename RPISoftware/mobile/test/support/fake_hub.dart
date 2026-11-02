import 'dart:convert';

import 'package:canary_resident/src/models/auth.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/hub_locator.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/hub_controller.dart';
import 'package:canary_resident/src/state/incident_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:canary_resident/src/ui/widgets/room_tiles.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef Reply = (int status, Object? body);

/// A scriptable hub: `routes['GET /api/v1/me']` → reply. Unrouted calls get
/// 404. Records every request (method, path, body).
class FakeHub implements HttpClientAdapter {
  FakeHub([Map<String, Reply Function(RequestOptions r)>? routes]) : routes = {...?routes};
  final Map<String, Reply Function(RequestOptions r)> routes;
  final requests = <RequestOptions>[];

  void on(String route, Reply Function(RequestOptions r) reply) => routes[route] = reply;
  void reply(String route, int status, [Object? body]) => routes[route] = (_) => (status, body);

  Iterable<RequestOptions> calls(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final handler = routes['${options.method} ${options.path}'];
    final (status, body) = handler == null ? (404, {'detail': 'Not Found'}) : handler(options);
    return ResponseBody.fromString(body == null ? '' : jsonEncode(body), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

ApiClient fakeApi(FakeHub hub, [String Function()? lang]) =>
    ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://hub.test'))..httpClientAdapter = hub, languageCode: lang);

/// Incident list without a WebSocket.
class FakeIncidents extends IncidentController {
  FakeIncidents(ApiClient api, Storage storage, [IncidentsState? initial]) : super(api, storage, null) {
    state = initial ?? const IncidentsState(connected: true);
  }
}

/// Phone-sized (360 dp) view with large text (1.3) and no platform plugins.
void phoneView(WidgetTester tester, {double textScale = 1.3}) {
  tester.view.physicalSize = const Size(360 * 3, 760 * 3);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  messenger.setMockMessageHandler(
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
    (_) async => const StandardMessageCodec().encodeMessage(<Object?>[null]),
  );
}

Future<Storage> signedInStorage({String role = 'resident', String language = 'ro', Map<String, Object> extra = const {}}) async {
  SharedPreferences.setMockInitialValues({
    'language': language,
    'session': jsonEncode(AuthSession(
      token: 't', userId: 'usr_ana', role: role, username: 'ana', buildingId: 'bld').toJson()),
    ...extra,
  });
  return Storage(await SharedPreferences.getInstance());
}

List<Override> hubOverrides(Storage storage, FakeHub hub, {IncidentsState? incidents}) => [
      storageProvider.overrideWithValue(storage),
      apiClientProvider.overrideWith((ref) => fakeApi(hub, () => ref.read(languageCodeProvider))),
      hubFound(storage),
      incidentControllerProvider.overrideWith(
        (ref) => FakeIncidents(ref.watch(apiClientProvider), storage, incidents)),
    ];

/// The hub is "found" at once (http://hub.test:8000): no network search in widget tests.
Override hubFound(Storage storage) => hubProvider.overrideWith((ref) => HubController(
      storage,
      ref.watch(apiClientProvider),
      locatorFor: (_) => HubLocator(
        probe: (_) async => true,
        browse: (_) async => const [],
        wifiIp: () async => null,
        override: 'http://hub.test:8000',
      ),
      probe: (_) async => true,
    ));

Future<void> settle(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// On the resident home: scrolls to the tile of the room [label] and opens it.
Future<void> openRoom(WidgetTester tester, String label) async {
  await tester.scrollUntilVisible(find.byType(RoomTileGrid), 200, scrollable: find.byType(Scrollable).first);
  final tile = find.descendant(of: find.byType(RoomTileGrid), matching: find.text(label)).first;
  await tester.ensureVisible(tile);
  await settle(tester, 3);
  await tester.tap(tile);
  await settle(tester);
}

/// On the resident home: opens "Toți senzorii" (every room card, list / sketch).
Future<void> openAllSensors(WidgetTester tester, {String label = 'Toți senzorii'}) async {
  final link = find.text(label);
  await tester.scrollUntilVisible(link, 200, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(link);
  await settle(tester, 3);
  await tester.tap(link);
  await settle(tester);
}

import 'dart:async';

import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/hub_locator.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/hub_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const hub = 'http://10.247.177.188:8000';

void main() {
  late Storage storage;
  late ApiClient api;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = await Storage.create();
    api = ApiClient();
  });

  HubLocator fixed(String? result, {String? Function(String?)? check, void Function()? onLocate}) => HubLocator(
        probe: (url) async => url == result,
        browse: (_) async {
          onLocate?.call();
          return [if (result != null) result];
        },
        wifiIp: () async => null,
      );

  test('finds the hub, points the API at it and saves it', () async {
    final c = HubController(storage, api, locatorFor: (_) => fixed(hub), probe: (u) async => u == hub);
    expect(c.state.searching, isTrue);
    await c.ready;
    expect(c.state.url, hub);
    expect(c.state.searching, isFalse);
    expect(api.baseUrl, hub);
    expect(storage.hubUrl, hub);
  });

  test('starts from the saved address', () async {
    await storage.saveHubUrl(hub);
    String? seenSaved;
    final c = HubController(storage, api, locatorFor: (saved) {
      seenSaved = saved;
      return fixed(hub);
    }, probe: (u) async => true);
    await c.ready;
    expect(seenSaved, hub);
  });

  test('nothing found: not searching, no address', () async {
    final c = HubController(storage, api, locatorFor: (_) => fixed(null), probe: (u) async => false);
    await c.ready;
    expect(c.state.url, isNull);
    expect(c.state.searching, isFalse);
  });

  test('unreachable hub triggers one search at a time and keeps the old address meanwhile', () async {
    var searches = 0;
    final gate = Completer<void>();
    final c = HubController(storage, api, locatorFor: (_) => HubLocator(
          probe: (url) async => url == hub,
          browse: (_) async {
            searches++;
            if (searches > 1) await gate.future;
            return [hub];
          },
          wifiIp: () async => null,
        ), probe: (u) async => true);
    await c.ready;
    expect(searches, 1);
    api.onUnreachable!();
    api.onUnreachable!();
    await Future<void>.delayed(Duration.zero);
    expect(searches, 2);
    expect(c.state.url, hub);
    expect(c.state.searching, isTrue);
    gate.complete();
    await c.ready;
    expect(c.state.searching, isFalse);
  });

  test('a typed address is used only if it answers as the hub', () async {
    final c = HubController(storage, api, locatorFor: (_) => fixed(null), probe: (u) async => u == hub);
    await c.ready;
    expect(await c.useManual('10.0.0.9'), isFalse);
    expect(c.state.url, isNull);
    expect(await c.useManual('10.247.177.188'), isTrue); // scheme and :8000 added
    expect(c.state.url, hub);
    expect(storage.hubUrl, hub);
    expect(await c.useManual('http://10.247.177.188:8000/'), isTrue);
    expect(c.state.url, hub);
  });

  test('a saved address is used at once while the search runs (cold start away from the hub)', () async {
    await storage.saveHubUrl(hub);
    final gate = Completer<void>();
    final c = HubController(storage, api, locatorFor: (_) => HubLocator(
          probe: (url) async {
            await gate.future;
            return false;
          },
          browse: (_) async => const [],
          wifiIp: () async => null,
        ), probe: (u) async => false);
    expect(c.state.url, hub);
    expect(c.state.searching, isTrue);
    expect(api.baseUrl, hub);
    gate.complete();
    await c.ready;
    expect(c.state.url, hub); // nothing better found: keep the saved one
  });

  test('a search that finds nothing does not stop later searches', () async {
    var searches = 0;
    final c = HubController(storage, api, locatorFor: (_) => HubLocator(
          probe: (url) async => false,
          browse: (_) async {
            searches++;
            return const [];
          },
          wifiIp: () async => null,
        ), probe: (u) async => false);
    await c.ready;
    for (var n = 0; n < 4; n++) {
      await expectLater(api.activeIncidents('b'), throwsA(isA<ApiException>()));
      await c.ready;
    }
    expect(searches, greaterThanOrEqualTo(3)); // the start, then again after each later failure
  });
}

import 'dart:async';
import 'dart:io';

import 'package:canary_resident/src/services/hub_locator.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/services/ws_client.dart';
import 'package:canary_resident/src/state/hub_controller.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// After a failover the hub is at another Pi's address: the live socket must follow it.
void main() {
  test('the live socket reports the hub unreachable after failed connects', () async {
    // A port nothing listens on: every connect fails at once.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final unreachable = Completer<void>();
    final ws = WsClient(
      baseUrl: 'http://127.0.0.1:$port',
      buildingId: 'b',
      token: 't',
      onUnreachable: () {
        if (!unreachable.isCompleted) unreachable.complete();
      },
    );
    ws.connect();
    await unreachable.future.timeout(const Duration(seconds: 6));
    await ws.dispose();
  });

  test('a new hub address rebuilds the incident controller (and so its socket)', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = await Storage.create();
    final container = ProviderContainer(overrides: [
      storageProvider.overrideWithValue(storage),
      hubProvider.overrideWith((ref) => HubController(
            storage,
            ref.watch(apiClientProvider),
            locatorFor: (_) => HubLocator(
              probe: (url) async => url == 'http://a:8000',
              browse: (_) async => const [],
              wifiIp: () async => null,
              override: 'http://a:8000',
            ),
            probe: (_) async => true,
          )),
    ]);
    addTearDown(container.dispose);
    await container.read(hubProvider.notifier).ready;
    final first = container.read(incidentControllerProvider.notifier);
    await container.read(hubProvider.notifier).useManual('http://b:8000');
    final second = container.read(incidentControllerProvider.notifier);
    expect(identical(first, second), isFalse);
  });
}

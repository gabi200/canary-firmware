import 'package:canary_resident/src/models/auth.dart';
import 'package:canary_resident/src/models/evacuation.dart';
import 'package:canary_resident/src/services/api_client.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _routeJson = <String, dynamic>{
  'assembly_points': [
    {'id': 'assembly', 'label': 'Courtyard'},
  ],
  'routes': [
    {
      'id': 'main-route',
      'label': 'Main exit',
      'to_assembly_point_id': 'assembly',
      'path': ['home', 'stairs', 'assembly'],
    },
  ],
};

class _FailingApiClient extends ApiClient {
  @override
  Future<Map<String, dynamic>> evacuationJson(String buildingId) async {
    throw ApiException('Hub unavailable');
  }
}

void main() {
  test('stores and loads evacuation JSON with its save time per building', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = Storage(await SharedPreferences.getInstance());

    await storage.saveEvacuation('building-a', _routeJson);

    final cached = storage.loadEvacuation('building-a');
    expect(cached?.json, _routeJson);
    expect(cached?.savedAt, isNotNull);
    expect(storage.loadEvacuation('building-b'), isNull);
  });

  test('treats a corrupt evacuation cache as unavailable', () async {
    SharedPreferences.setMockInitialValues({
      'evacuation_cache_building-a': 'not JSON',
    });
    final storage = Storage(await SharedPreferences.getInstance());

    expect(storage.loadEvacuation('building-a'), isNull);
  });

  test('uses the saved evacuation route when the hub request fails', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = Storage(await SharedPreferences.getInstance());
    const session = AuthSession(
      token: 'token',
      userId: 'resident',
      role: 'resident',
      username: 'Resident',
      buildingId: 'building-a',
    );
    await storage.saveSession(session);
    await storage.saveEvacuation('building-a', _routeJson);
    final container = ProviderContainer(overrides: [
      storageProvider.overrideWithValue(storage),
      apiClientProvider.overrideWithValue(_FailingApiClient()),
    ]);
    addTearDown(container.dispose);

    final info = await container.read(evacuationProvider.future);

    expect(info, isA<EvacuationInfo>());
    expect(info.routes.single.id, 'main-route');
    expect(info.savedAt, isNotNull);
  });
}

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/unit_scope.dart';
import '../models/summary.dart';
import '../models/zone_info.dart';
import '../services/storage.dart';
import 'dashboard_providers.dart';
import 'providers.dart';

/// The apartment / room picked over the sensor lists, shared by the dashboard,
/// home and "Testează senzorii". Remembered on this device for the building
/// (unit / zone ids only); a choice from another building is ignored.
class ScopeChoiceController extends StateNotifier<ScopeChoice> {
  ScopeChoiceController(this._storage, this._buildingId) : super(_load(_storage, _buildingId));
  final Storage _storage;
  final String? _buildingId;

  static ScopeChoice _load(Storage storage, String? buildingId) {
    final raw = storage.sensorScope;
    if (raw == null || buildingId == null) return ScopeChoice.none;
    try {
      final j = jsonDecode(raw);
      return j is Map && j['building'] == buildingId ? ScopeChoice.fromJson(j) : ScopeChoice.none;
    } catch (_) {
      return ScopeChoice.none;
    }
  }

  Future<void> set(ScopeChoice choice) async {
    if (choice == state) return;
    state = choice;
    final buildingId = _buildingId;
    if (buildingId == null) return;
    await _storage.setSensorScope(jsonEncode({'building': buildingId, ...choice.toJson()}));
  }
}

final scopeChoiceProvider = StateNotifierProvider<ScopeChoiceController, ScopeChoice>((ref) {
  final buildingId = ref.watch(sessionProvider.select((s) => s?.buildingId));
  return ScopeChoiceController(ref.watch(storageProvider), buildingId);
});

/// The picker over the hub summary's rooms with sensors (home / dashboard).
final summaryScopeProvider = Provider.autoDispose<SensorScope>((ref) {
  final zones = ref.watch(summaryProvider.select((s) => s.summary?.zones)) ?? const <ZoneSummary>[];
  final infos = ref.watch(zonesInfoProvider).valueOrNull ?? const <ZoneInfo>[];
  return resolveScope(
    [
      for (final z in zones)
        if (z.nodes.isNotEmpty) (z, z.nodes),
    ],
    {for (final z in infos) z.id: z},
    ref.watch(scopeChoiceProvider),
    staff: !(ref.watch(sessionProvider)?.isResident ?? true),
  );
});

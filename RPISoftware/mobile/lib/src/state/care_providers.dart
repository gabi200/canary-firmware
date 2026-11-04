import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/care_profile.dart';
import '../models/check_in.dart';
import '../models/me.dart';
import '../services/api_client.dart';
import '../services/health_import.dart';
import '../services/storage.dart';
import 'account_providers.dart';
import 'providers.dart';

/// The signed-in resident's care profiles ("Profil de urgență"). Health data:
/// held in memory only for the session (dropped on logout), fetched from the
/// hub when first needed and refreshed on demand — never written to disk.
class CareProfilesController extends AsyncNotifier<List<CareProfile>> {
  @override
  Future<List<CareProfile>> build() async {
    final session = ref.watch(sessionProvider);
    if (session == null || !session.isResident) return const [];
    final api = ref.watch(apiClientProvider);
    final other = await otherBuildingUnitIds(ref);
    return _inThisBuilding(await api.careProfiles(), other);
  }

  /// Profiles on a home of another building belong to the other mode's screens.
  List<CareProfile> _inThisBuilding(List<CareProfile> all, Set<String> other) =>
      [for (final p in all) if (!other.contains(p.unitId)) p];

  ApiClient get _api => ref.read(apiClientProvider);

  /// Refetch, keeping the current list on screen meanwhile.
  Future<void> refresh() async {
    state = const AsyncLoading<List<CareProfile>>().copyWithPrevious(state);
    state = await AsyncValue.guard(() async {
      final other = (await ref.read(meProvider.future))?.otherUnitIds ?? const <String>{};
      return _inThisBuilding(await _api.careProfiles(), other);
    });
  }

  /// Create ([id] null) or update; throws [ApiException] (422 / 404 / 409 / 503).
  Future<CareProfile> save(CareProfileDraft draft, {String? id}) async {
    final saved = id == null ? await _api.createCareProfile(draft) : await _api.updateCareProfile(id, draft);
    final list = [...?state.valueOrNull];
    final i = list.indexWhere((p) => p.id == saved.id);
    if (i >= 0) {
      list[i] = saved;
    } else {
      list.add(saved);
    }
    state = AsyncData(list);
    return saved;
  }

  Future<void> delete(String id) async {
    await _api.deleteCareProfile(id);
    state = AsyncData([...?state.valueOrNull?.where((p) => p.id != id)]);
  }
}

final careProfilesProvider =
    AsyncNotifierProvider<CareProfilesController, List<CareProfile>>(CareProfilesController.new);

/// Name to prefill and the caller's unit(s) for the profile form: the
/// residential units of `GET /me`. On a hub without that endpoint it falls
/// back to the units of existing profiles, then to the units of the
/// resident's own (non-common) zones.
final myHouseholdProvider = FutureProvider.autoDispose<MyHousehold>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const MyHousehold(units: []);
  final api = ref.watch(apiClientProvider);

  MeProfile? me;
  try {
    me = await ref.watch(meProvider.future);
  } on ApiException {
    me = null; // unreachable / not allowed: use the fallbacks below
  }
  var units = me?.residentialUnits ?? const <UnitRef>[];

  if (units.isEmpty) {
    final profiles = ref.read(careProfilesProvider).valueOrNull ?? const <CareProfile>[];
    units = {for (final p in profiles) if (p.unitId.isNotEmpty) UnitRef(p.unitId, p.unitLabel)}.toList();
  }
  if (units.isEmpty) {
    final summary = await api.summary(session.buildingId);
    final zoneUnits = await api.zoneUnits(session.buildingId);
    units = [
      for (final id in ownUnitIds(visibleZoneIds: summary.zones.map((z) => z.zoneId), zoneUnits: zoneUnits))
        UnitRef(id),
    ];
  }

  String? selfName;
  for (final p in ref.read(careProfilesProvider).valueOrNull ?? const <CareProfile>[]) {
    if (p.isSelf) selfName = p.displayName;
  }
  final username = session.username;
  final fallbackName = username.isEmpty ? null : '${username[0].toUpperCase()}${username.substring(1)}';
  return MyHousehold(units: units, displayName: me?.displayName ?? selfName ?? fallbackName);
});

/// Whether the home "add an emergency profile" hint was dismissed (persisted;
/// only this flag is stored on the device).
class CareHintController extends StateNotifier<bool> {
  CareHintController(this._storage) : super(_storage.careHintDismissed);
  final Storage _storage;

  Future<void> dismiss() async {
    state = true;
    await _storage.setCareHintDismissed();
  }
}

final careHintDismissedProvider = StateNotifierProvider<CareHintController, bool>(
  (ref) => CareHintController(ref.watch(storageProvider)),
);

/// Status of one household member's check-in during an incident.
class CareCheckIn {
  const CareCheckIn({required this.status, this.sending = false, this.failed = false});
  final CheckInStatus status;
  final bool sending;
  final bool failed;
  bool get sent => !sending && !failed;
}

/// Household check-ins for one incident, by care profile id. In memory; a
/// failed send shows an error with retry and never blocks the resident.
class CareCheckInController extends StateNotifier<Map<String, CareCheckIn>> {
  CareCheckInController(this._api, this._incidentId) : super(const {});
  final ApiClient _api;
  final String _incidentId;

  Future<void> send(String profileId, CheckInStatus status) async {
    state = {...state, profileId: CareCheckIn(status: status, sending: true)};
    try {
      await _api.careCheckIn(_incidentId, profileId, status);
      if (mounted) state = {...state, profileId: CareCheckIn(status: status)};
    } catch (_) {
      if (mounted) state = {...state, profileId: CareCheckIn(status: status, failed: true)};
    }
  }

  /// Back to the status buttons for [profileId].
  void change(String profileId) => state = {...state}..remove(profileId);
}

final careCheckInProvider =
    StateNotifierProvider.family<CareCheckInController, Map<String, CareCheckIn>, String>(
  (ref, incidentId) => CareCheckInController(ref.watch(apiClientProvider), incidentId),
);

/// Apple Health import (overridden in tests).
final healthImportProvider = Provider<HealthImport>((ref) => const HealthImport());

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/relative_location.dart';
import '../models/check_in.dart';
import '../models/me.dart';
import '../models/zone_info.dart';
import '../services/api_client.dart';
import '../services/storage.dart';
import 'account_providers.dart';
import 'dashboard_providers.dart';
import 'providers.dart';

/// The signed-in resident's homes ("Ap. 12 · Etaj 3"): their units from
/// `GET /me`, else (older hub) the apartments of the zones their summary lists,
/// which are only their own. Floors come from the building's zone list.
final residentHomeProvider = Provider.autoDispose<ResidentHome>((ref) {
  final zones = ref.watch(zonesInfoProvider).valueOrNull ?? const <ZoneInfo>[];
  final me = ref.watch(meProvider).valueOrNull;
  final own = <({String id, String? label, String? floorLabel})>[
    for (final u in me?.units ?? const <MeUnit>[])
      if (u.kind == null || u.kind == 'residential') (id: u.unitId, label: u.unitLabel, floorLabel: u.floorLabel),
  ];
  if (own.isEmpty) {
    final byId = {for (final z in zones) z.id: z};
    for (final z in ref.watch(summaryProvider.select((s) => s.summary?.zones)) ?? const []) {
      final info = byId[z.zoneId];
      final unitId = z.unitId ?? info?.unitId;
      if (unitId == null || unitId.isEmpty || (info?.isCommon ?? unitId.toLowerCase().contains('common'))) continue;
      own.add((id: unitId, label: z.unitLabel ?? info?.unitLabel, floorLabel: info?.floorLabel));
    }
  }
  return residentHome(own, zones);
});

/// The resident's answer to "Unde ești acum?" for one incident: kept on this
/// device for this account (so it survives a restart) and sent to the hub,
/// where the latest answer wins.
class ResidentLocationController extends StateNotifier<ResidentLocation?> {
  ResidentLocationController(this._api, this._storage, this._incidentId, String? userId)
      : _key = '${userId ?? ''}/$_incidentId',
        super(ResidentLocation.fromToken(_storage.incidentLocation('${userId ?? ''}/$_incidentId')));

  final ApiClient _api;
  final Storage _storage;
  final String _incidentId;

  /// Storage key: the account and the incident.
  final String _key;

  /// Remembers [where], then sends it; false when the hub couldn't be reached
  /// (the answer stays on the phone and can be sent again).
  Future<bool> answer(ResidentLocation where) async {
    state = where;
    await _storage.setIncidentLocation(_key, where.token);
    try {
      await _api.reportLocation(_incidentId, where);
      return true;
    } catch (_) {
      return false;
    }
  }
}

final residentLocationProvider =
    StateNotifierProvider.autoDispose.family<ResidentLocationController, ResidentLocation?, String>(
  (ref, incidentId) => ResidentLocationController(ref.watch(apiClientProvider), ref.watch(storageProvider), incidentId,
      ref.watch(sessionProvider.select((s) => s?.userId))),
);

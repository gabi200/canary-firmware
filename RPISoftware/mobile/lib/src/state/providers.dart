import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth.dart';
import '../models/evacuation.dart';
import '../services/api_client.dart';
import '../services/storage.dart';
import 'incident_controller.dart';
import 'session_controller.dart';
import 'summary_controller.dart';

/// Overridden in main() with the initialized SharedPreferences-backed instance.
final storageProvider = Provider<Storage>(
  (ref) => throw UnimplementedError('storageProvider must be overridden in main()'),
);

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final sessionProvider = StateNotifierProvider<SessionController, AuthSession?>(
  (ref) => SessionController(ref.watch(storageProvider), ref.watch(apiClientProvider)),
);

/// Live incidents for the signed-in resident's building. Only read while a
/// session exists (the UI gates on sessionProvider).
final incidentControllerProvider =
    StateNotifierProvider<IncidentController, IncidentsState>((ref) {
  final session = ref.watch(sessionProvider);
  // Tolerates a null session (idle controller) so transient rebuilds during
  // logout don't throw; the UI still gates real screens on sessionProvider.
  return IncidentController(
    ref.watch(apiClientProvider),
    ref.watch(storageProvider),
    session,
  );
});

/// Hub analysis of the building's sensors (analysis only, never raw values).
/// Rides the incident controller's WebSocket for live `node` events.
final summaryProvider = StateNotifierProvider<SummaryController, SummaryState>((ref) {
  return SummaryController(
    ref.watch(apiClientProvider),
    ref.watch(sessionProvider),
    ref.watch(incidentControllerProvider.notifier).liveEvents,
  );
});

final evacuationProvider = FutureProvider.autoDispose<EvacuationInfo>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) {
    return const EvacuationInfo(routes: [], assemblyPoints: []);
  }
  // Read dependencies before the first await: the home-screen prefetch reads this
  // provider without listening, so it may be disposed before the fetch completes.
  final api = ref.watch(apiClientProvider);
  final storage = ref.watch(storageProvider);
  try {
    final raw = await api.evacuationJson(session.buildingId);
    final info = EvacuationInfo.fromJson(raw);
    try {
      await storage.saveEvacuation(session.buildingId, raw);
    } catch (_) {
      // A fresh hub route is still safe to show if local persistence is unavailable.
    }
    return info;
  } catch (error, stackTrace) {
    final cached = storage.loadEvacuation(session.buildingId);
    if (cached != null) {
      try {
        final info = EvacuationInfo.fromJson(cached.json);
        return EvacuationInfo(
          routes: info.routes,
          assemblyPoints: info.assemblyPoints,
          savedAt: cached.savedAt,
        );
      } catch (_) {
        // A malformed route cache is not safe to show.
      }
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
});

/// Presence-contribution consent (explicit opt-in; off by default).
class ConsentController extends StateNotifier<bool> {
  ConsentController(this._storage) : super(_storage.presenceConsent);
  final Storage _storage;

  Future<void> set(bool value) async {
    await _storage.setPresenceConsent(value);
    state = value;
  }
}

final consentProvider = StateNotifierProvider<ConsentController, bool>(
  (ref) => ConsentController(ref.watch(storageProvider)),
);

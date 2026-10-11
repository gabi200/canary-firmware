import 'dart:ui' show Locale;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../models/auth.dart';
import '../models/evacuation.dart';
import '../services/api_client.dart';
import '../services/storage.dart';
import 'incident_controller.dart';
import 'locale_controller.dart';
import 'session_controller.dart';
import 'summary_controller.dart';
import 'theme_controller.dart';

/// Overridden in main() with the initialized SharedPreferences-backed instance.
final storageProvider = Provider<Storage>(
  (ref) => throw UnimplementedError('storageProvider must be overridden in main()'),
);

/// Active app language (RO / EN); see LocaleController for default + persistence.
final localeProvider = StateNotifierProvider<LocaleController, Locale>(
  (ref) => LocaleController(ref.watch(storageProvider)),
);

/// Light / dark / follow the phone; Dark by default (see ThemeModeController).
final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(ref.watch(storageProvider)),
);

/// 'ro' | 'en'. Providers holding backend text watch/listen to this so they
/// refetch in the new language.
final languageCodeProvider = Provider<String>((ref) => ref.watch(localeProvider).languageCode);

/// Strings for the active language, for code without a BuildContext.
final l10nProvider = Provider<AppLocalizations>(
  (ref) => lookupAppLocalizations(ref.watch(localeProvider)),
);

/// One client for the app's lifetime (it holds the session token); it reads the
/// language per request rather than being rebuilt on a switch.
final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(languageCode: () => ref.read(languageCodeProvider)),
);

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
    localizations: () => ref.read(l10nProvider),
  );
});

/// Hub analysis of the building's sensors (analysis only, never raw values).
/// Rides the incident controller's WebSocket for live `node` events.
final summaryProvider = StateNotifierProvider<SummaryController, SummaryState>((ref) {
  final controller = SummaryController(
    ref.watch(apiClientProvider),
    ref.watch(sessionProvider),
    ref.watch(incidentControllerProvider.notifier).liveEvents,
  );
  // Headlines, advice and indicator values are hub text in the request's
  // Accept-Language: refetch in place (keeping the last summary on screen).
  ref.listen<String>(languageCodeProvider, (_, __) => controller.reload());
  return controller;
});

final evacuationProvider = FutureProvider.autoDispose<EvacuationInfo>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) {
    return const EvacuationInfo(routes: [], assemblyPoints: []);
  }
  ref.watch(languageCodeProvider); // refetch on a language switch
  return ref.watch(apiClientProvider).evacuation(session.buildingId);
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

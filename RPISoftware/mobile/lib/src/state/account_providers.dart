import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/me.dart';
import 'providers.dart';

/// The signed-in account (`GET /me`), in memory for the session; null on a hub
/// without the endpoint. Rebuilt on login / logout.
class MeController extends AsyncNotifier<MeProfile?> {
  @override
  Future<MeProfile?> build() async {
    if (ref.watch(sessionProvider) == null) return null;
    return ref.watch(apiClientProvider).me();
  }

  /// `PATCH /me` with only [changes]; the hub's answer (normalized phone, ...)
  /// becomes the new state. Throws [ApiException] (422 with field messages).
  Future<MeProfile> save(Map<String, String> changes) async {
    final me = await ref.read(apiClientProvider).updateMe(changes);
    state = AsyncData(me);
    return me;
  }
}

final meProvider = AsyncNotifierProvider<MeController, MeProfile?>(MeController.new);

/// Tells the hub the app language (`PATCH /me {"language"}`) after login and on
/// every RO / EN switch, so server-side notifications arrive in that language.
/// Older hubs answer 404 / 422: ignored, the app works the same.
final languageSyncProvider = Provider<void>((ref) {
  if (ref.watch(sessionProvider) == null) return;
  final language = ref.watch(languageCodeProvider);
  ref.read(apiClientProvider).updateMe({'language': language}).then((_) {}, onError: (Object _) {});
});

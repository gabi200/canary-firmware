import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth.dart';
import '../services/api_client.dart';
import '../services/storage.dart';

/// Owns the authenticated session. Restores a persisted session on construction
/// so a returning resident skips onboarding.
class SessionController extends StateNotifier<AuthSession?> {
  SessionController(this._storage, this._api) : super(null) {
    final saved = _storage.loadSession();
    if (saved != null) {
      _api.setToken(saved.token);
      state = saved;
    }
  }

  final Storage _storage;
  final ApiClient _api;

  Future<void> login(String username, String buildingId) async {
    final session = await _api.login(username, buildingId);
    _api.setToken(session.token);
    await _storage.saveSession(session);
    state = session;
  }

  Future<void> logout() async {
    await _storage.clearSession();
    _api.setToken(null);
    state = null;
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../models/auth.dart';
import '../services/api_client.dart';
import '../services/storage.dart';

/// Owns the authenticated session. Restores a persisted session on construction
/// so a returning resident skips onboarding.
class SessionController extends StateNotifier<AuthSession?> {
  SessionController(this._storage, this._api) : super(null) {
    // an expired session lands on the sign-in screen instead of "hub unreachable"
    _api.onUnauthorized = () {
      if (mounted && state != null) logout();
    };
    final saved = _storage.loadSession();
    if (saved != null) {
      _api.setToken(saved.token);
      state = saved;
    }
  }

  final Storage _storage;
  final ApiClient _api;

  /// Signs in on the building the hub's mode shows (the default building when
  /// the hub can't say); the mode poll keeps it in step afterwards.
  Future<void> login(String username) async {
    var session = await _api.login(username, Config.defaultBuildingId);
    _api.setToken(session.token);
    try {
      session = session.copyWith(buildingId: (await _api.hubMode()).buildingId);
    } catch (_) {
      // keep the default; the next mode poll corrects it
    }
    await _storage.saveSession(session);
    state = session;
  }

  /// The hub's mode moved to another building: every per-building provider,
  /// the poll and the WebSocket rebuild from the new session, and it is saved.
  Future<void> switchBuilding(String buildingId) async {
    final current = state;
    if (current == null || current.buildingId == buildingId) return;
    final next = current.copyWith(buildingId: buildingId);
    await _storage.saveSession(next);
    state = next;
  }

  Future<void> logout() async {
    await _storage.clearSession();
    _api.setToken(null);
    state = null;
  }
}

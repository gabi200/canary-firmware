import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hub_mode.dart';
import '../services/api_client.dart';
import 'providers.dart';
import 'session_controller.dart';

export '../models/hub_mode.dart';

/// Polls the hub's demo / real mode and moves the session to the building the
/// mode shows. The session change rebuilds the per-building providers, the
/// incident WebSocket and the saved session. Phones only follow: no switch.
class ModeController extends StateNotifier<HubMode?> {
  ModeController(this._api, this._session, {required bool enabled}) : super(null) {
    if (!enabled) return;
    _timer = Timer.periodic(pollInterval, (_) => poll());
    poll();
  }

  static const pollInterval = Duration(seconds: 5);

  final ApiClient _api;
  final SessionController _session;
  Timer? _timer;
  bool _busy = false;

  /// One poll. A failure changes nothing (the current building stays) and the
  /// timer keeps going.
  Future<void> poll() async {
    if (_busy) return;
    _busy = true;
    try {
      final mode = await _api.hubMode();
      if (!mounted) return;
      state = mode;
      await _session.switchBuilding(mode.buildingId);
    } catch (e) {
      debugPrint('Canary: mode poll failed: $e');
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// The hub's mode, polled every 5 s while signed in (null until the first
/// answer, and while signed out, when nothing is polled).
final hubModeProvider = StateNotifierProvider<ModeController, HubMode?>((ref) {
  final signedIn = ref.watch(sessionProvider.select((s) => s?.token)) != null;
  return ModeController(ref.watch(apiClientProvider), ref.read(sessionProvider.notifier), enabled: signedIn);
});

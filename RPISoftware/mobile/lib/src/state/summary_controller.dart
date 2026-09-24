import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth.dart';
import '../models/summary.dart';
import '../services/api_client.dart';

@immutable
class SummaryState {
  const SummaryState({this.summary, this.updatedAt, this.error});

  /// Last good summary; kept when a refresh fails so the section never blanks.
  final BuildingSummary? summary;

  /// When [summary] was fetched (device clock).
  final DateTime? updatedAt;

  /// Why the latest refresh failed, or null when it succeeded.
  final String? error;
}

/// Hub sensor analysis for the signed-in building (HARDWARE.md §4). Loads on
/// start, then refetches on live `node` / `incident` events (at most once per
/// [minEventGap]), on a slow fallback poll, and on pull-to-refresh.
class SummaryController extends StateNotifier<SummaryState> {
  SummaryController(this._api, this._session, Stream<Map<String, dynamic>> liveEvents)
      : super(const SummaryState()) {
    if (_session == null) return;
    _events = liveEvents.listen(_onLiveEvent);
    _poll = Timer.periodic(pollInterval, (_) => refresh());
    refresh();
  }

  static const minEventGap = Duration(seconds: 5);
  static const pollInterval = Duration(seconds: 30);

  final ApiClient _api;
  final AuthSession? _session;
  StreamSubscription<Map<String, dynamic>>? _events;
  Timer? _poll;
  Timer? _pending;
  DateTime? _lastFetch;
  Future<void>? _inFlight;

  void _onLiveEvent(Map<String, dynamic> ev) {
    final type = ev['type'];
    // `node`: a sensor's analysis changed. `incident`: the building status and
    // headline also depend on open incidents. Anything else is ignored.
    if (type != 'node' && type != 'incident') return;
    if (_pending?.isActive ?? false) return; // a refresh is already queued
    final last = _lastFetch;
    final elapsed = last == null ? minEventGap : DateTime.now().difference(last);
    _pending = Timer(elapsed >= minEventGap ? Duration.zero : minEventGap - elapsed, refresh);
  }

  /// Refetch now; concurrent callers share the in-flight request.
  Future<void> refresh() => _inFlight ??= _fetch().whenComplete(() => _inFlight = null);

  Future<void> _fetch() async {
    final session = _session;
    if (session == null) return;
    _pending?.cancel();
    _lastFetch = DateTime.now();
    try {
      final summary = await _api.summary(session.buildingId);
      if (mounted) state = SummaryState(summary: summary, updatedAt: DateTime.now());
    } catch (e) {
      debugPrint('Canary: summary refresh failed: $e');
      if (mounted) {
        state = SummaryState(summary: state.summary, updatedAt: state.updatedAt, error: e.toString());
      }
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _poll?.cancel();
    _pending?.cancel();
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../logic/connection_status.dart';
import '../models/auth.dart';
import '../models/check_in.dart';
import '../models/incident.dart';
import '../services/api_client.dart';
import '../services/notifications.dart';
import '../services/storage.dart';
import '../services/ws_client.dart';

enum CheckInResult { sent, queued }

@immutable
class IncidentsState {
  const IncidentsState({
    this.incidents = const [],
    this.connected = false,
    this.lastMessageAt,
    this.pending = 0,
    this.eventSeq = 0,
  });
  final List<Incident> incidents;
  final bool connected;
  final DateTime? lastMessageAt;
  final int pending;

  /// Monotonic counter bumped on every live WebSocket frame (incident transition or
  /// resident check-in). Dashboards listen on this to refetch accounting/roster live.
  final int eventSeq;

  Incident? get activeAlarm {
    for (final i in incidents) {
      if (i.isAlarming) return i;
    }
    return null;
  }

  IncidentsState copyWith({
    List<Incident>? incidents,
    bool? connected,
    DateTime? lastMessageAt,
    int? pending,
    int? eventSeq,
  }) =>
      IncidentsState(
        incidents: incidents ?? this.incidents,
        connected: connected ?? this.connected,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        pending: pending ?? this.pending,
        eventSeq: eventSeq ?? this.eventSeq,
      );
}

/// Merges the initial REST snapshot with the live WebSocket stream, raises a
/// notification when the building enters an alarming state, and manages the
/// offline check-in queue (flushed when the socket reconnects).
class IncidentController extends StateNotifier<IncidentsState> {
  IncidentController(this._api, this._storage, this._session)
      : super(IncidentsState(pending: _storage.pendingCheckIns().length)) {
    if (_session != null) _init();
  }

  final ApiClient _api;
  final Storage _storage;
  final AuthSession? _session;
  WsClient? _ws;
  StreamSubscription<bool>? _connectionSub;
  StreamSubscription<DateTime>? _messageSub;
  Timer? _freshnessTimer;
  bool _flushing = false;
  final Set<String> _alarmed = {};
  final _live = StreamController<Map<String, dynamic>>.broadcast();

  /// Every decoded WebSocket frame, re-broadcast for other live views (the
  /// sensor summary refetches on `node` events).
  Stream<Map<String, dynamic>> get liveEvents => _live.stream;

  Future<void> _init() async {
    await refresh();
    _connectWs();
    _freshnessTimer = Timer.periodic(const Duration(seconds: 5), (_) => _checkFreshness());
  }

  Future<void> refresh() async {
    final session = _session;
    if (session == null) return;
    try {
      final list = await _api.activeIncidents(session.buildingId);
      state = state.copyWith(incidents: list);
    } catch (e) {
      debugPrint('Canary: incident refresh failed: $e');
    }
  }

  void _connectWs() {
    final session = _session;
    if (session == null) return;
    final ws = WsClient(buildingId: session.buildingId, token: session.token);
    _ws = ws;
    ws.events.listen(_onEvent);
    _messageSub = ws.messages.listen(_onMessage);
    _connectionSub = ws.connection.listen(_onConnection);
    ws.connect();
  }

  // The socket's onDone fires after dispose (logout); don't touch state then.
  void _setConnected(bool v) {
    if (mounted) state = state.copyWith(connected: v);
  }

  void _onMessage(DateTime receivedAt) {
    if (!mounted) return;
    state = state.copyWith(lastMessageAt: receivedAt);
    // Any frame (including the 15 s ping) proves the hub is reachable; retry queued check-ins.
    if (state.pending > 0) flushQueue();
  }

  void _onConnection(bool connected) {
    if (!mounted) return;
    if (connected) {
      // The signal follows the first frame. Set a timestamp here too so stream delivery
      // ordering can never display Live without a recent server frame.
      final wasConnected = state.connected;
      state = state.copyWith(connected: true, lastMessageAt: DateTime.now());
      if (!wasConnected) flushQueue();
    } else {
      _setConnected(false);
    }
  }

  void _checkFreshness() {
    if (mounted && state.connected && !isConnectionFresh(state.lastMessageAt, DateTime.now())) {
      _setConnected(false);
    }
  }

  void _onEvent(Map<String, dynamic> ev) {
    if (!mounted) return;
    _live.add(ev);
    final type = ev['type'];
    // Sensor analysis update (HARDWARE.md §5): never an incident, and no eventSeq
    // bump — these arrive on every sensor heartbeat and would make manager
    // dashboards refetch accounting/roster continuously.
    if (type == 'node') return;
    // Any live frame advances eventSeq so manager dashboards refetch accounting/roster.
    state = state.copyWith(eventSeq: state.eventSeq + 1);
    if (type != 'incident') {
      // e.g. "checkin" — no incident upsert, but the bump above drives a roster refresh.
      return;
    }
    final incident = Incident.fromWsEvent(ev);
    _upsert(incident);

    if (incident.isAlarming && !_alarmed.contains(incident.id + incident.state)) {
      _alarmed.add(incident.id + incident.state);
      Notifications.instance.showAlarm(
        (ev['title'] as String?) ?? '${incident.hazardLabel} alert',
        (ev['body'] as String?) ?? 'Open Canary for guidance.',
        critical: incident.severity == 'critical' || incident.isEvacuation,
      );
    }
  }

  void _upsert(Incident incident) {
    final list = [...state.incidents];
    final idx = list.indexWhere((i) => i.id == incident.id);
    if (incident.isClosed) {
      if (idx >= 0) list.removeAt(idx);
    } else if (idx >= 0) {
      list[idx] = incident;
    } else {
      list.insert(0, incident);
    }
    state = state.copyWith(incidents: list);
  }

  Future<CheckInResult> submitCheckIn(String incidentId, CheckInStatus status) async {
    try {
      await _api.checkIn(incidentId, status);
      return CheckInResult.sent;
    } catch (_) {
      await _storage.enqueueCheckIn(
        PendingCheckIn(incidentId: incidentId, status: status.token, queuedAt: DateTime.now()),
      );
      state = state.copyWith(pending: _storage.pendingCheckIns().length);
      return CheckInResult.queued;
    }
  }

  Future<void> flushQueue() async {
    if (_flushing) return;
    final pending = _storage.pendingCheckIns();
    if (pending.isEmpty) return;
    _flushing = true;
    try {
      await _flush(pending);
    } finally {
      _flushing = false;
    }
  }

  Future<void> _flush(List<PendingCheckIn> pending) async {
    final stillPending = <PendingCheckIn>[];
    for (final p in pending) {
      final status = CheckInStatus.values.firstWhere(
        (s) => s.token == p.status,
        orElse: () => CheckInStatus.safeOutside,
      );
      try {
        await _api.checkIn(p.incidentId, status);
      } catch (_) {
        stillPending.add(p);
      }
    }
    // Keep check-ins queued while this flush was in flight (after the snapshot, in order).
    final queuedMeanwhile = _storage.pendingCheckIns().skip(pending.length);
    final remaining = [...stillPending, ...queuedMeanwhile];
    await _storage.replaceQueue(remaining);
    if (mounted) state = state.copyWith(pending: remaining.length);
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    _connectionSub?.cancel();
    _messageSub?.cancel();
    _ws?.dispose();
    _live.close();
    super.dispose();
  }
}

/// Convenience flags for the UI.
extension IncidentStateX on IncidentsState {
  bool get isNormal => activeAlarm == null;
  String get buildingStatusLabel => activeAlarm == null ? 'All clear' : activeAlarm!.state;
}

/// Alarming-states reference re-exported for the UI layer.
const alarmingStates = Config.alarmingStates;

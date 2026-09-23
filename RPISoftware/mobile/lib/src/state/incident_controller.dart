import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
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
    this.pending = 0,
    this.eventSeq = 0,
  });
  final List<Incident> incidents;
  final bool connected;
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

  IncidentsState copyWith({List<Incident>? incidents, bool? connected, int? pending, int? eventSeq}) =>
      IncidentsState(
        incidents: incidents ?? this.incidents,
        connected: connected ?? this.connected,
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
  final Set<String> _alarmed = {};

  Future<void> _init() async {
    await refresh();
    _connectWs();
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
    ws.events.listen(_onEvent, onDone: () => _setConnected(false));
    ws.connect();
    _setConnected(true);
    // socket up -> try to drain any queued check-ins
    flushQueue();
  }

  void _setConnected(bool v) => state = state.copyWith(connected: v);

  void _onEvent(Map<String, dynamic> ev) {
    final type = ev['type'] as String?;
    // Any live frame advances eventSeq so manager dashboards refetch accounting/roster.
    state = state.copyWith(eventSeq: state.eventSeq + 1);
    if (type != 'incident') {
      // e.g. "checkin" — no incident upsert, but the bump above drives a roster refresh.
      flushQueue();
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
    // any inbound event implies connectivity; opportunistically flush the queue
    flushQueue();
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
    final pending = _storage.pendingCheckIns();
    if (pending.isEmpty) return;
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
    await _storage.replaceQueue(stillPending);
    state = state.copyWith(pending: stillPending.length);
  }

  @override
  void dispose() {
    _ws?.dispose();
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

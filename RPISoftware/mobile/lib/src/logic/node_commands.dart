import 'package:flutter/foundation.dart';

import '../models/node_command.dart';
import '../models/summary.dart';
import '../models/zone_info.dart';

/// Where one press of a test button is. `sending`: the request is on its way.
/// `sent`: the hub relayed it, waiting for the device. Then exactly one final
/// phase: the device's answer (accepted / rejected), no answer within
/// [CommandRun.timeout] (timeout), or the hub refused to send it (failed).
enum RunPhase { sending, sent, accepted, rejected, timeout, failed }

@immutable
class CommandRun {
  const CommandRun({
    required this.nodeId,
    required this.command,
    required this.phase,
    required this.startedAt,
    this.commandId,
    this.detail,
    this.httpStatus,
  });

  factory CommandRun.start(String nodeId, NodeCommandType command, DateTime now) =>
      CommandRun(nodeId: nodeId, command: command, phase: RunPhase.sending, startedAt: now);

  /// No answer by then: "Fără răspuns".
  static const timeout = Duration(seconds: 15);

  final String nodeId;
  final NodeCommandType command;
  final RunPhase phase;
  final DateTime startedAt;

  /// The hub's id, known once it accepted the request.
  final String? commandId;

  /// Device detail code (accepted / rejected), or the hub's error text (failed).
  final String? detail;

  /// HTTP status when the hub refused to send (409 offline, 429 too soon, ...).
  final int? httpStatus;

  bool get isActive => phase == RunPhase.sending || phase == RunPhase.sent;
  bool get isFinal => !isActive;

  CommandRun _to(RunPhase phase, {String? commandId, String? detail, int? httpStatus}) => CommandRun(
        nodeId: nodeId,
        command: command,
        phase: phase,
        startedAt: startedAt,
        commandId: commandId ?? this.commandId,
        detail: detail ?? this.detail,
        httpStatus: httpStatus ?? this.httpStatus,
      );

  /// The hub took the command (202) and relayed it to the device.
  CommandRun sent(String commandId) => phase == RunPhase.sending ? _to(RunPhase.sent, commandId: commandId) : this;

  /// The hub refused to send it (no HTTP answer: [status] null).
  CommandRun failed(int? status, String? detail) =>
      phase == RunPhase.sending ? _to(RunPhase.failed, httpStatus: status, detail: detail) : this;

  /// A result from the WebSocket or the command list. Applies only while
  /// waiting for the device, to this very command; `sent` changes nothing.
  CommandRun result(String commandId, CommandStatus status, {String? detail}) {
    if (phase != RunPhase.sent || commandId != this.commandId) return this;
    return switch (status) {
      CommandStatus.sent => this,
      CommandStatus.accepted => _to(RunPhase.accepted, detail: detail),
      CommandStatus.rejected => _to(RunPhase.rejected, detail: detail),
      CommandStatus.timeout => _to(RunPhase.timeout, detail: detail),
    };
  }

  /// No answer in time (local clock).
  CommandRun timedOut() => isActive ? _to(RunPhase.timeout) : this;
}

/// May the signed-in user command a sensor?
enum CommandAccess {
  /// Show the test buttons.
  allowed,

  /// A resident looking at a common area: "only the manager can test these".
  commonArea,

  /// Nothing to show (dispatcher, someone else's unit, zone not known yet).
  none,
}

/// Managers and admins command every sensor; residents only those in zones of
/// their own units ([ownUnitIds] from `/me`; empty = not known, then any
/// non-common zone); dispatchers none (the hub answers 403).
CommandAccess commandAccess({required String? role, required ZoneInfo? zone, Set<String> ownUnitIds = const {}}) {
  switch (role) {
    case 'hoa_manager' || 'system_admin':
      return CommandAccess.allowed;
    case 'resident':
      if (zone == null) return CommandAccess.none;
      if (zone.isCommon) return CommandAccess.commonArea;
      if (ownUnitIds.isNotEmpty && !ownUnitIds.contains(zone.unitId)) return CommandAccess.none;
      return CommandAccess.allowed;
    default:
      return CommandAccess.none;
  }
}

/// Valve position from the hub's `valve` indicator: true open, false closed,
/// null unknown (then both buttons show).
bool? valveOpen(NodeAnalysis node) => switch (node.indicator('valve')?.level) {
      'ok' => true,
      'attention' => false,
      _ => null,
    };

/// The newest `last_command` among [nodes] (a room's), or null.
NodeCommand? latestCommand(Iterable<NodeAnalysis> nodes) {
  NodeCommand? best;
  for (final n in nodes) {
    final c = n.lastCommand;
    if (c == null) continue;
    final ts = c.ts;
    final bestTs = best?.ts;
    if (best == null || (ts != null && (bestTs == null || ts.isAfter(bestTs)))) best = c;
  }
  return best;
}

/// "Testează toate alarmele": TEST each sensor in turn, never two at once —
/// each waits for the previous result and starts at least [spacing] after the
/// previous start (the hub refuses commands < 3 s apart; 5 s lets each 4-second
/// self-test sound alone). Only ever sends what [send] sends (TEST); never a
/// valve command.
class SequentialTestRunner {
  SequentialTestRunner({
    required this.send,
    this.spacing = const Duration(seconds: 5),
    Future<void> Function(Duration)? wait,
    DateTime Function()? clock,
  })  : assert(spacing >= const Duration(seconds: 3)),
        _wait = wait ?? Future<void>.delayed,
        _clock = clock ?? DateTime.now;

  /// Sends one TEST and completes with the final run.
  final Future<CommandRun> Function(String nodeId) send;
  final Duration spacing;
  final Future<void> Function(Duration) _wait;
  final DateTime Function() _clock;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  /// Stops before the next sensor (the current one finishes on its own).
  void cancel() => _cancelled = true;

  Future<Map<String, CommandRun>> run(List<String> nodeIds) async {
    final results = <String, CommandRun>{};
    DateTime? lastStart;
    for (final id in nodeIds) {
      if (_cancelled) break;
      if (lastStart != null) {
        final left = spacing - _clock().difference(lastStart);
        if (left > Duration.zero) await _wait(left);
        if (_cancelled) break;
      }
      lastStart = _clock();
      results[id] = await send(id);
    }
    return results;
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/node_commands.dart';
import '../models/node_command.dart';
import '../services/api_client.dart';
import 'providers.dart';

/// The latest test-button press per sensor (node id → run), live: sends the
/// command, follows the device's answer on the WebSocket (`command_result`),
/// polls the command list as a fallback while waiting, and gives up after
/// [CommandRun.timeout]. One command at a time per sensor.
class NodeCommandController extends StateNotifier<Map<String, CommandRun>> {
  NodeCommandController(
    this._api,
    Stream<Map<String, dynamic>> liveEvents, {
    this.onSettled,
    this.timeout = CommandRun.timeout,
    this.pollEvery = const Duration(seconds: 3),
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        super(const {}) {
    _events = liveEvents.listen(_onEvent);
  }

  final ApiClient _api;

  /// Called once a run is final (e.g. refetch the summary's `last_command`).
  final VoidCallback? onSettled;
  final Duration timeout;
  final Duration pollEvery;
  final DateTime Function() _clock;
  StreamSubscription<Map<String, dynamic>>? _events;
  final _tracks = <String, _Track>{};

  /// Results that arrived before the hub's 202 (command id → result).
  final _early = <String, ({CommandStatus status, String? detail})>{};

  /// Sends [command] to [nodeId]; completes with the final run. While one is
  /// active for that sensor, returns that one instead of sending another.
  Future<CommandRun> send(String nodeId, NodeCommandType command) async {
    final active = _tracks[nodeId];
    if (active != null) return active.done.future;
    final track = _Track();
    _tracks[nodeId] = track;
    _put(CommandRun.start(nodeId, command, _clock()));
    track.timeout = Timer(timeout, () => _apply(nodeId, track, (r) => r.timedOut()));
    try {
      final cmd = await _api.sendNodeCommand(nodeId, command);
      _apply(nodeId, track, (r) => r.sent(cmd.commandId));
      final early = _early.remove(cmd.commandId);
      if (early != null) {
        _apply(nodeId, track, (r) => r.result(cmd.commandId, early.status, detail: early.detail));
      } else if (cmd.status.isFinal) {
        _apply(nodeId, track, (r) => r.result(cmd.commandId, cmd.status, detail: cmd.detail));
      }
      if (_tracks[nodeId] == track) {
        track.poll = Timer.periodic(pollEvery, (_) => _poll(nodeId, track, cmd.commandId));
      }
    } on ApiException catch (e) {
      _apply(nodeId, track, (r) => r.failed(e.statusCode, e.detail));
    } catch (e) {
      _apply(nodeId, track, (r) => r.failed(null, null));
    }
    return track.done.future;
  }

  void _onEvent(Map<String, dynamic> ev) {
    if (ev['type'] != 'command_result') return;
    final nodeId = ev['node_id'];
    final commandId = ev['command_id'];
    final status = CommandStatus.parse(ev['status']);
    if (nodeId is! String || commandId is! String || status == null) return;
    final detail = ev['detail'] is String && (ev['detail'] as String).isNotEmpty ? ev['detail'] as String : null;
    final track = _tracks[nodeId];
    if (track == null) return;
    if (state[nodeId]?.phase == RunPhase.sending) {
      // Raced ahead of the 202; applied once the id is known.
      _early[commandId] = (status: status, detail: detail);
      return;
    }
    _apply(nodeId, track, (r) => r.result(commandId, status, detail: detail));
  }

  Future<void> _poll(String nodeId, _Track track, String commandId) async {
    try {
      final list = await _api.nodeCommands(nodeId, limit: 5);
      for (final c in list) {
        if (c.commandId == commandId && c.status.isFinal) {
          _apply(nodeId, track, (r) => r.result(commandId, c.status, detail: c.detail));
          return;
        }
      }
    } catch (e) {
      debugPrint('Canary: command poll failed: $e');
    }
  }

  /// Updates [nodeId]'s run if [track] is still the live one; settles it once final.
  void _apply(String nodeId, _Track track, CommandRun Function(CommandRun) change) {
    if (!mounted || _tracks[nodeId] != track) return;
    final run = state[nodeId];
    if (run == null) return;
    final next = change(run);
    if (identical(next, run)) return;
    _put(next);
    if (next.isFinal) {
      _tracks.remove(nodeId);
      track.close(next);
      onSettled?.call();
    }
  }

  void _put(CommandRun run) => state = {...state, run.nodeId: run};

  @override
  void dispose() {
    _events?.cancel();
    for (final entry in _tracks.entries) {
      final run = state[entry.key];
      entry.value.close(run?.timedOut());
    }
    _tracks.clear();
    super.dispose();
  }
}

class _Track {
  final done = Completer<CommandRun>();
  Timer? timeout;
  Timer? poll;

  void close(CommandRun? run) {
    timeout?.cancel();
    poll?.cancel();
    if (!done.isCompleted && run != null) done.complete(run);
  }
}

/// Test-button runs for the session; rides the incidents WebSocket.
final nodeCommandsProvider = StateNotifierProvider<NodeCommandController, Map<String, CommandRun>>((ref) {
  return NodeCommandController(
    ref.watch(apiClientProvider),
    ref.watch(incidentControllerProvider.notifier).liveEvents,
    // The hub's `last_command` changed: refresh the room cards' "Ultimul test".
    onSettled: () => ref.read(summaryProvider.notifier).refresh(),
  );
});

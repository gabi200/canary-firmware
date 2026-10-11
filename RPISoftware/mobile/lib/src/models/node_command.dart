// Device commands (HARDWARE.md §4): `POST /nodes/{id}/commands`. Air sensors
// take TEST (4-second self-test: buzzer + LED) and SILENCE; water sensors OPEN /
// CLOSE (the valve) and SILENCE. The hub answers 202 "sent", then the device's
// result arrives as a WebSocket `command_result` (or via the command list).

enum NodeCommandType {
  test('TEST'),
  silence('SILENCE'),
  open('OPEN'),
  close('CLOSE');

  const NodeCommandType(this.wire);

  /// Token on the wire ("TEST", ...).
  final String wire;

  static NodeCommandType? parse(Object? v) {
    if (v is! String) return null;
    final up = v.toUpperCase();
    for (final c in values) {
      if (c.wire == up) return c;
    }
    return null;
  }

  /// What a sensor of [kind] (air | water) understands.
  static List<NodeCommandType> forKind(String kind) => switch (kind) {
        'air' => const [test, silence],
        'water' => const [close, open, silence],
        _ => const [],
      };
}

/// Hub status of a command: `sent` (waiting for the device), then one of
/// accepted / rejected / timeout.
enum CommandStatus {
  sent,
  accepted,
  rejected,
  timeout;

  static CommandStatus? parse(Object? v) => switch (v) {
        'sent' => sent,
        'accepted' => accepted,
        'rejected' => rejected,
        'timeout' => timeout,
        _ => null,
      };

  bool get isFinal => this != sent;
}

/// One command as the hub records it (202 answer, list item, `last_command`).
class NodeCommand {
  const NodeCommand({
    required this.commandId,
    required this.command,
    required this.status,
    this.nodeId,
    this.detail,
    this.requestedByName,
    this.sentTs,
    this.resultTs,
  });

  final String commandId;

  /// Wire token as recorded ("TEST", ...); [type] when the app knows it.
  final String command;
  final CommandStatus status;
  final String? nodeId;

  /// Device detail code ("self_test", "alarm_inactive", ...), or null.
  final String? detail;
  final String? requestedByName;
  final DateTime? sentTs;
  final DateTime? resultTs;

  NodeCommandType? get type => NodeCommandType.parse(command);

  /// When it last changed: the result time, else when it was sent.
  DateTime? get ts => resultTs ?? sentTs;

  /// Null when [j] is not a command object (missing id or unknown status).
  static NodeCommand? tryParse(Object? j) {
    if (j is! Map) return null;
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    DateTime? ts(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final id = str(j['command_id']);
    final status = CommandStatus.parse(j['status']);
    if (id == null || status == null) return null;
    return NodeCommand(
      commandId: id,
      command: str(j['command']) ?? '',
      status: status,
      nodeId: str(j['node_id']),
      detail: str(j['detail']),
      requestedByName: str(j['requested_by_name']),
      sentTs: ts(j['sent_ts']),
      resultTs: ts(j['result_ts']),
    );
  }
}

/// Resident check-in statuses (must match backend app.enums.CheckInStatus tokens).
enum CheckInStatus {
  safeOutside('safe_outside', "I'm safe / evacuated"),
  safeInside('safe_inside', "Safe but still inside"),
  needsHelp('needs_help', 'I need help');

  const CheckInStatus(this.token, this.label);
  final String token;
  final String label;
}

/// A check-in queued locally while offline, replayed on reconnect.
class PendingCheckIn {
  const PendingCheckIn({required this.incidentId, required this.status, required this.queuedAt});
  final String incidentId;
  final String status; // CheckInStatus.token
  final DateTime queuedAt;

  Map<String, dynamic> toJson() => {
        'incidentId': incidentId,
        'status': status,
        'queuedAt': queuedAt.toIso8601String(),
      };

  factory PendingCheckIn.fromJson(Map<String, dynamic> j) => PendingCheckIn(
        incidentId: j['incidentId'] as String,
        status: j['status'] as String,
        queuedAt: DateTime.parse(j['queuedAt'] as String),
      );
}

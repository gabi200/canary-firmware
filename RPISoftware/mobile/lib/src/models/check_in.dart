/// Resident check-in statuses (must match backend app.enums.CheckInStatus tokens).
/// Display text: `AppLocalizations.checkInLabel()` (lib/src/i18n.dart).
enum CheckInStatus {
  safeOutside('safe_outside'),
  safeInside('safe_inside'),
  needsHelp('needs_help');

  const CheckInStatus(this.token);
  final String token;
}

/// Where the resident says they are during an incident ("Unde ești acum?"),
/// sent with `POST /incidents/{id}/location` (must match the backend tokens).
/// Display text: `AppLocalizations.whereNowLabel()` (lib/src/i18n.dart).
enum ResidentLocation {
  home('home'),
  building('building'),
  outside('outside');

  const ResidentLocation(this.token);
  final String token;

  static ResidentLocation? fromToken(String? token) {
    for (final l in values) {
      if (l.token == token) return l;
    }
    return null;
  }
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

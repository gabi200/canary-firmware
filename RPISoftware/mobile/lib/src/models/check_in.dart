import '../../l10n/gen/app_localizations.dart';

/// Resident check-in statuses (must match backend app.enums.CheckInStatus tokens).
enum CheckInStatus {
  safeOutside('safe_outside'),
  safeInside('safe_inside'),
  needsHelp('needs_help');

  const CheckInStatus(this.token);
  final String token;
  String label(AppLocalizations l10n) => switch (this) {
        CheckInStatus.safeOutside => l10n.safeOutside,
        CheckInStatus.safeInside => l10n.safeInside,
        CheckInStatus.needsHelp => l10n.needsHelp,
      };
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

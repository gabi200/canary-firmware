import '../../l10n/gen/app_localizations.dart';

const connectionStaleAfter = Duration(seconds: 40);

/// Protocol frames used to prove liveness, not to update incident data.
bool isConnectionControlFrame(Map<String, dynamic> frame) =>
    frame['type'] == 'hello' || frame['type'] == 'ping';

bool isConnectionFresh(DateTime? lastMessageAt, DateTime now) =>
    lastMessageAt != null && now.difference(lastMessageAt) < connectionStaleAfter;

String liveConnectionLabel(
  AppLocalizations l10n, {
  required DateTime? lastMessageAt,
  required DateTime now,
}) {
  if (lastMessageAt == null) return l10n.liveJustNow;
  final seconds = now.difference(lastMessageAt).inSeconds.clamp(0, 1 << 31);
  return seconds < 5 ? l10n.liveJustNow : l10n.liveUpdated(seconds);
}

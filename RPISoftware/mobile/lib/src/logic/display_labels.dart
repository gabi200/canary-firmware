import '../../l10n/gen/app_localizations.dart';

/// Human-readable text for internal identifiers and canonical incident states.
String humanizeId(String? id) {
  if (id == null || id.trim().isEmpty) return '—';
  final words = id
      .trim()
      .replaceFirst(RegExp(r'^(zone|unit|flr|floor|bld|dev)_', caseSensitive: false), '')
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .split(' ');
  return words
      .where((word) => word.isNotEmpty)
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

/// Friendly zone name from a label map, with a humanized identifier fallback.
String prettyZone(Map<String, String>? labels, String? id) {
  final label = id == null ? null : labels?[id]?.trim();
  return label == null || label.isEmpty ? humanizeId(id) : label;
}

String incidentStateLabel(AppLocalizations l10n, String state) => switch (state) {
      'detection' => l10n.stateDetection,
      'verification' => l10n.stateVerification,
      'alarm' => l10n.stateAlarm,
      'evacuation' => l10n.stateEvacuation,
      'escalation' => l10n.stateEscalation,
      'resolution' => l10n.stateResolution,
      'false_alarm' => l10n.stateFalseAlarm,
      'normal' => l10n.stateNormal,
      _ => humanizeId(state),
    };

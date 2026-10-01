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

String incidentStateLabel(String state) => switch (state) {
      'detection' => 'Detected',
      'verification' => 'Verifying',
      'alarm' => 'Alarm',
      'evacuation' => 'Evacuate now',
      'escalation' => 'Emergency response',
      'resolution' => 'Resolved',
      'false_alarm' => 'False alarm',
      'normal' => 'All clear',
      _ => humanizeId(state),
    };

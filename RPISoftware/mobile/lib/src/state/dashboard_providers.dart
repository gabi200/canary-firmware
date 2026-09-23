import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dashboard.dart';
import 'providers.dart';

/// Victim-accounting for an incident (occupants / accounted / unaccounted / needs help).
final accountingProvider =
    FutureProvider.autoDispose.family<Accounting, String>((ref, incidentId) {
  return ref.watch(apiClientProvider).accounting(incidentId);
});

/// Named resident roster + live check-in status for an incident.
final rosterProvider =
    FutureProvider.autoDispose.family<Roster, String>((ref, incidentId) {
  return ref.watch(apiClientProvider).roster(incidentId);
});

/// Building zone id -> human label map (e.g. "zone_kitchen" -> "Bucătărie").
final zoneLabelsProvider = FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const {};
  return ref.watch(apiClientProvider).zoneLabels(session.buildingId);
});

/// Friendly zone name from a label map, with a prettified fallback.
String prettyZone(Map<String, String>? labels, String? id) {
  if (id == null || id.isEmpty) return '—';
  final label = labels?[id];
  if (label != null && label.isNotEmpty) return label;
  return id
      .replaceFirst(RegExp(r'^(zone|unit|flr|floor|bld|dev)_', caseSensitive: false), '')
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

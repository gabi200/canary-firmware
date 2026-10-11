import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/dashboard.dart';
import '../models/zone_info.dart';
import '../services/storage.dart';
import 'providers.dart';

/// Victim-accounting for an incident (occupants / accounted / unaccounted / needs help).
final accountingProvider =
    FutureProvider.autoDispose.family<Accounting, String>((ref, incidentId) {
  ref.watch(languageCodeProvider); // refetch on a language switch
  return ref.watch(apiClientProvider).accounting(incidentId);
});

/// Named resident roster + live check-in status for an incident.
final rosterProvider =
    FutureProvider.autoDispose.family<Roster, String>((ref, incidentId) {
  ref.watch(languageCodeProvider); // refetch on a language switch
  return ref.watch(apiClientProvider).roster(incidentId);
});

/// Building zone id -> human label map (e.g. "zone_kitchen" -> "Bucătărie").
final zoneLabelsProvider = FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const {};
  ref.watch(languageCodeProvider); // refetch on a language switch
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

/// A zone's name with its unit ("Bucătărie · Ap. 12"), for staff screens that
/// name a room away from its apartment (each flat has a "Bucătărie").
String zoneWithUnit(Map<String, String>? labels, Iterable<ZoneInfo>? zones, String? id) {
  final name = prettyZone(labels, id);
  final unit = zones?.where((z) => z.id == id).firstOrNull?.unitLabel;
  return unit == null || unit == name ? name : '$name · $unit';
}

/// Zones with positions, for the home sketch (building data, shown as sent).
final zonesInfoProvider = FutureProvider.autoDispose<List<ZoneInfo>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.watch(apiClientProvider).zones(session.buildingId);
});

/// "Starea locuinței" view, 'list' | 'sketch' (persisted; default list).
class HomeViewController extends StateNotifier<String> {
  HomeViewController(this._storage) : super(_storage.homeStatusView == 'sketch' ? 'sketch' : 'list');
  final Storage _storage;

  Future<void> set(String view) async {
    state = view;
    await _storage.setHomeStatusView(view);
  }
}

final homeViewProvider = StateNotifierProvider<HomeViewController, String>(
  (ref) => HomeViewController(ref.watch(storageProvider)),
);

/// What the resident has folded on the home list: collapsed sections ('rooms',
/// 'building') and rooms whose sensors show inline. Kept on this device.
typedef HomeFold = ({Set<String> collapsed, Set<String> openRooms});

class HomeFoldController extends StateNotifier<HomeFold> {
  HomeFoldController(this._storage)
      : super((collapsed: _storage.sectionsCollapsed.toSet(), openRooms: _storage.roomsExpanded.toSet()));
  final Storage _storage;

  Future<void> toggleSection(String id) async {
    final collapsed = {...state.collapsed};
    if (!collapsed.remove(id)) collapsed.add(id);
    state = (collapsed: collapsed, openRooms: state.openRooms);
    await _storage.setSectionsCollapsed(collapsed.toList());
  }

  Future<void> toggleRoom(String zoneId) async {
    final open = {...state.openRooms};
    if (!open.remove(zoneId)) open.add(zoneId);
    state = (collapsed: state.collapsed, openRooms: open);
    await _storage.setRoomsExpanded(open.toList());
  }
}

final homeFoldProvider = StateNotifierProvider<HomeFoldController, HomeFold>(
  (ref) => HomeFoldController(ref.watch(storageProvider)),
);

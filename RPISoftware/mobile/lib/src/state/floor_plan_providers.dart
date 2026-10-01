import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/zone.dart';
import 'providers.dart';

/// Zone positions for the signed-in resident's building (floor-plan schematic).
final zonesProvider = FutureProvider.autoDispose<List<ZoneInfo>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.watch(apiClientProvider).zones(session.buildingId);
});

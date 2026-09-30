import '../models/evacuation.dart';

enum RouteSafety { clear, crosses, unknown }

class RouteChoice {
  const RouteChoice({required this.route, required this.safety});

  final EvacuationRoute route;
  final RouteSafety safety;
  bool get crossesHazard => safety == RouteSafety.crosses;
}

RouteChoice? selectRoute(
  EvacuationInfo info, {
  Set<String> hazardZoneIds = const {},
  String? userZoneId,
}) {
  RouteChoice? best;
  var bestRank = 6;
  for (final route in info.routes) {
    final safety = route.path.isEmpty || hazardZoneIds.isEmpty
        ? RouteSafety.unknown
        : route.path.asMap().entries.any((entry) =>
            hazardZoneIds.contains(entry.value) &&
            !(entry.key == 0 && entry.value == userZoneId))
            ? RouteSafety.crosses
            : RouteSafety.clear;
    final rank = (switch (safety) {
      RouteSafety.clear => 0,
      RouteSafety.unknown => 2,
      RouteSafety.crosses => 4,
    }) +
        (route.fromZoneId == userZoneId && userZoneId != null ? 0 : 1);
    if (rank < bestRank) {
      best = RouteChoice(route: route, safety: safety);
      bestRank = rank;
    }
  }
  return best;
}

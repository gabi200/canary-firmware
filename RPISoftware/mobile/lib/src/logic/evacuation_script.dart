import '../../l10n/gen/app_localizations.dart';
import '../models/evacuation.dart';
import 'route_selection.dart';

/// Creates the ordered instructions read to a resident during an evacuation.
String buildEvacuationScript({
  required AppLocalizations l10n,
  required String hazardDont,
  required List<Waypoint> waypoints,
  required RouteSafety? safety,
  String? avoidZoneName,
  String? assemblyPointName,
}) {
  final instructions = <String>[];
  final avoidName = avoidZoneName?.trim();
  instructions.add(hazardDont);
  if (avoidName != null && avoidName.isNotEmpty) instructions.add(l10n.avoid(avoidName));

  switch (safety) {
    case RouteSafety.crosses:
      instructions.add(l10n.routeCrossesHazard);
      break;
    case RouteSafety.unknown:
      instructions.add(l10n.routeSafetyUnknown);
      break;
    case RouteSafety.clear:
    case null:
      break;
  }

  if (waypoints.isEmpty) {
    instructions.add(l10n.fallbackLeave);
  } else {
    for (var index = 0; index < waypoints.length; index++) {
      final waypoint = waypoints[index];
      final hint = waypoint.hint.trim();
      instructions.add(l10n.routeStep(
        index + 1,
        waypoints.length,
        waypoint.label,
        hint.isEmpty ? '' : ' $hint',
      ));
    }
    final assemblyName = assemblyPointName?.trim();
    if (assemblyName != null && assemblyName.isNotEmpty) {
      instructions.add(l10n.spokenAssembly(assemblyName));
    }
  }

  return instructions
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map(_asSentence)
      .join(' ');
}

/// Ends a line with punctuation so speech engines pause between instructions
/// (hub hints and "Avoid: <zone>" usually have none).
String _asSentence(String line) =>
    RegExp(r'[.!?…]$').hasMatch(line) ? line : '$line.';

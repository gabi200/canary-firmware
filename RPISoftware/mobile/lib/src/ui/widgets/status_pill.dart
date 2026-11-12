import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../theme.dart';

/// Small pill showing a hazard/incident state (or hub analysis level), labelled
/// in the app language unless [label] is given: state text on a soft tint, in
/// sentence case. Evacuation alone is a solid deep red with white text.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.state, this.label, this.color});
  final String state;
  final String? label;

  /// Overrides the incident-state color (e.g. for hub analysis levels).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final solid = color ?? HazardColors.forState(state);
    final evacuation = color == null && state == 'evacuation';
    final text = sentenceCase(label ?? context.l10n.statusLabel(state));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: evacuation ? HazardColors.evacuation : palette.tint(solid, 34),
        borderRadius: BorderRadius.circular(CanaryRadius.control),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: evacuation ? Colors.white : palette.ink(solid),
          fontWeight: FontWeight.w600,
          fontSize: 12,
          height: 1.3,
        ),
      ),
    );
  }
}

/// "evacuare" -> "Evacuare": state labels are stored lower case for use inside
/// sentences; standing alone (pills, state lines) they start with a capital.
String sentenceCase(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

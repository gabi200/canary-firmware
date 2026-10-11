import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../theme.dart';

/// Small colored pill showing a hazard/incident state (or hub analysis level),
/// labelled in the app language unless [label] is given.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.state, this.label, this.color});
  final String state;
  final String? label;

  /// Overrides the incident-state color (e.g. for hub analysis levels).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = context.palette.ink(this.color ?? HazardColors.forState(state));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Text(
        (label ?? context.l10n.statusLabel(state)).toUpperCase(),
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 0.5),
      ),
    );
  }
}

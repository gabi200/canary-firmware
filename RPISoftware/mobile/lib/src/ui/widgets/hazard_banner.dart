import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../models/incident.dart';
import '../../theme.dart';
import 'safety_sign.dart';
import 'classification_text.dart';

class HazardBanner extends StatelessWidget {
  const HazardBanner({super.key, required this.incident, this.zoneLabel, this.onTap});
  final Incident incident;

  /// Where it is, in words (room name / relative place); the zone id otherwise.
  final String? zoneLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = HazardColors.forState(incident.state);
    final l10n = context.l10n;
    final hazard = l10n.hazardName(incident.hazardType);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              SafetySignImage(hazardSign(incident.hazardType), size: 44),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      incident.isEvacuation ? l10n.evacuateNow : hazard.toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [hazard, l10n.statusLabel(incident.state), if ((zoneLabel ?? incident.primaryZoneId) case final String z) z]
                          .join(' · '),
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    ClassificationText(incident: incident, color: Colors.white),
                  ],
                ),
              ),
              if (onTap != null) const Icon(Icons.chevron_right, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../models/incident.dart';
import '../../theme.dart';
import 'home_banner.dart';
import 'safety_sign.dart';
import 'classification_text.dart';

/// An open incident as the console's incident banner: filled by state (amber with
/// dark ink for detection, the alarm fill for alarm, deep red plus the hazard tape
/// for evacuation), the hazard sign on a white disc.
class HazardBanner extends StatelessWidget {
  const HazardBanner({super.key, required this.incident, this.zoneLabel, this.onTap});
  final Incident incident;

  /// Where it is, in words (room name / relative place); the zone id otherwise.
  final String? zoneLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fill = HazardColors.bannerFill(incident.state);
    final ink = HazardColors.onBanner(incident.state);
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    final hazard = l10n.hazardName(incident.hazardType);
    return ClipRRect(
      borderRadius: BorderRadius.circular(CanaryRadius.container),
      child: Material(
        color: fill,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (incident.isEvacuation) const HazardTape(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
                child: Row(
                  children: [
                    SafetySignDisc(hazardSign(incident.hazardType), size: 44),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(incident.isEvacuation ? l10n.evacuateNow : hazard,
                              style: text.headlineSmall!.copyWith(color: ink)),
                          const SizedBox(height: 4),
                          Text(
                            [
                              hazard,
                              l10n.statusLabel(incident.state),
                              if ((zoneLabel ?? incident.primaryZoneId) case final String z) z,
                            ].join(' · '),
                            style: text.bodyMedium!.copyWith(color: ink),
                          ),
                          ClassificationText(incident: incident, color: ink),
                        ],
                      ),
                    ),
                    if (onTap != null) Icon(Icons.chevron_right, color: ink),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

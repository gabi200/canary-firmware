import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../models/incident.dart';
import '../../theme.dart';
import 'home_banner.dart';
import 'safety_sign.dart';
import 'classification_text.dart';

/// The EVACUATE NOW banner on the manager dashboard: deep red with the hazard tape
/// along its top. Motion is one calm signal: only the exit sign pulses (scale 1.06,
/// opacity 0.88, 1.2 s); the fill stays still, and so does the sign under reduced
/// motion (DESIGN.md, Incident banner).
class FlashingEvacuateBanner extends StatefulWidget {
  const FlashingEvacuateBanner({super.key, required this.incident, this.zoneLabel, this.onTap});
  final Incident incident;
  final String? zoneLabel;
  final VoidCallback? onTap;

  @override
  State<FlashingEvacuateBanner> createState() => _FlashingEvacuateBannerState();
}

class _FlashingEvacuateBannerState extends State<FlashingEvacuateBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final l10n = context.l10n;
    final text = Theme.of(context).textTheme;
    const sign = SafetySignDisc(SafetySign.e002, size: 48);
    final pulse = reduceMotion
        ? sign
        : AnimatedBuilder(
            animation: _c,
            builder: (_, child) {
              final t = Curves.easeInOut.transform(_c.value);
              return Opacity(opacity: 1 - 0.12 * t, child: Transform.scale(scale: 1 + 0.06 * t, child: child));
            },
            child: sign,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(CanaryRadius.container),
      child: Material(
        color: HazardColors.evacuation,
        child: InkWell(
          onTap: widget.onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const HazardTape(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 12, 16),
                child: Row(
                  children: [
                    pulse,
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.evacuateNow, style: text.headlineMedium!.copyWith(color: Colors.white)),
                          const SizedBox(height: 4),
                          Text(
                            [
                              l10n.hazardName(widget.incident.hazardType),
                              if ((widget.zoneLabel ?? widget.incident.primaryZoneId) case final String z) z,
                            ].join(' · '),
                            style: text.bodyMedium!.copyWith(color: Colors.white),
                          ),
                          ClassificationText(incident: widget.incident, color: Colors.white),
                        ],
                      ),
                    ),
                    if (widget.onTap != null) const Icon(Icons.chevron_right, color: Colors.white),
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

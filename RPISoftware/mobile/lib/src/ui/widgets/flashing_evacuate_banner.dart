import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../models/incident.dart';
import '../../theme.dart';
import 'safety_sign.dart';
import 'classification_text.dart';

/// High-urgency EVACUATE NOW banner that flashes (~1 Hz) to grab attention on the
/// phone. Falls back to a static red banner when the OS requests reduced motion.
class FlashingEvacuateBanner extends StatefulWidget {
  const FlashingEvacuateBanner({super.key, required this.incident, this.zoneLabel, this.onTap});
  final Incident incident;
  final String? zoneLabel;
  final VoidCallback? onTap;

  @override
  State<FlashingEvacuateBanner> createState() => _FlashingEvacuateBannerState();
}

class _FlashingEvacuateBannerState extends State<FlashingEvacuateBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final l10n = context.l10n;

    Widget banner(double t) {
      final bg = Color.lerp(HazardColors.evacuation, const Color(0xFFF44336), t)!;
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFF44336).withValues(alpha: 0.55 * t),
              blurRadius: 24 * t,
              spreadRadius: 2 * t,
            ),
          ],
          border: const Border.symmetric(
            horizontal: BorderSide(color: Color(0xFFF5C518), width: 4),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Transform.scale(
                    scale: 1 + 0.12 * t,
                    child: const SafetySignImage(SafetySign.e002, size: 46),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.evacuateNow,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${l10n.hazardName(widget.incident.hazardType)} · ${widget.zoneLabel ?? widget.incident.primaryZoneId ?? ''}',
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                        ClassificationText(incident: widget.incident, color: Colors.white),
                      ],
                    ),
                  ),
                  if (widget.onTap != null) const Icon(Icons.chevron_right, color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (reduceMotion) return banner(0);
    return AnimatedBuilder(animation: _c, builder: (_, __) => banner(_c.value));
  }
}

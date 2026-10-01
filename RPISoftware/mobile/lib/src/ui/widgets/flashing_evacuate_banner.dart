import 'package:flutter/material.dart';

import '../../models/incident.dart';
import '../../logic/display_labels.dart';
import '../../theme.dart';

/// High-urgency EVACUATE NOW banner that flashes (~1 Hz) to grab attention on the
/// phone. Falls back to a static red banner when the OS requests reduced motion.
class FlashingEvacuateBanner extends StatefulWidget {
  const FlashingEvacuateBanner({
    super.key,
    required this.incident,
    required this.zoneLabel,
    this.onTap,
  });
  final Incident incident;
  final String zoneLabel;
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

    Widget banner(double t) {
      final bg = Color.lerp(HazardColors.evacuation, HazardColors.evacuationPulse, t)!;
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: HazardColors.evacuationPulse.withOpacity(0.55 * t),
              blurRadius: 24 * t,
              spreadRadius: 2 * t,
            ),
          ],
          border: const Border.symmetric(
            horizontal: BorderSide(color: HazardColors.evacuationBorder, width: 4),
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
                    child: const Icon(Icons.directions_run, color: HazardColors.onHazard, size: 46),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'EVACUATE NOW',
                          style: TextStyle(
                            color: HazardColors.onHazard,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.incident.hazardLabel} · '
                          '${widget.zoneLabel.trim().isEmpty ? humanizeId(widget.incident.primaryZoneId) : widget.zoneLabel}',
                          style: const TextStyle(color: HazardColors.onHazard, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onTap != null) const Icon(Icons.chevron_right, color: HazardColors.onHazard),
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

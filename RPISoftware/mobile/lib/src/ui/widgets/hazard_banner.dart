import 'package:flutter/material.dart';

import '../../models/incident.dart';
import '../../theme.dart';

class HazardBanner extends StatelessWidget {
  const HazardBanner({super.key, required this.incident, this.onTap});
  final Incident incident;
  final VoidCallback? onTap;

  IconData get _icon {
    switch (incident.hazardType) {
      case 'combustible_gas':
        return Icons.local_fire_department;
      case 'co':
        return Icons.cloud;
      case 'water_leak':
        return Icons.water_drop;
      default:
        return Icons.warning_amber_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = HazardColors.forState(incident.state);
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
              Icon(_icon, color: Colors.white, size: 44),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      incident.isEvacuation ? 'EVACUATE NOW' : incident.hazardLabel.toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${incident.hazardLabel} · ${incident.state} · ${incident.primaryZoneId ?? ''}',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
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

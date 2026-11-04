import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../models/incident.dart';
import '../../theme.dart';

class ClassificationText extends StatelessWidget {
  const ClassificationText({super.key, required this.incident, this.color});

  final Incident incident;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (!incident.hasClassification) return const SizedBox.shrink();
    final signature = incident.signature!;
    final l10n = context.l10n;
    String assessment(String? label, double? confidence) => [
          l10n.classificationName(label),
          if (confidence != null) '${l10n.count((confidence * 100).round())}%',
        ].join(' ');
    return Text(
      '${l10n.classificationRule}: ${assessment(signature.label, signature.confidence)}'
      '${signature.shadowLabel == null ? '' : ' · ${l10n.classificationModel}: ${assessment(signature.shadowLabel, signature.shadowConfidence)}'}',
      style: TextStyle(fontSize: 12, color: color ?? context.palette.muted),
    );
  }
}

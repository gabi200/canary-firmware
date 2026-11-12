import 'package:flutter/material.dart';

import '../../logic/safety_signs.dart';

export '../../logic/safety_signs.dart';

/// An official ISO 7010 sign. Long-press shows its name in the app language.
/// Use [decorative] inside buttons whose label already says what the sign means.
class SafetySignImage extends StatelessWidget {
  const SafetySignImage(this.sign, {super.key, this.size = 40, this.decorative = false});

  final SafetySign sign;
  final double size;
  final bool decorative;

  @override
  Widget build(BuildContext context) {
    final name = sign.nameFor(Localizations.maybeLocaleOf(context)?.languageCode ?? 'en');
    final image = Image.asset(sign.asset,
        width: size, height: size, fit: BoxFit.contain,
        semanticLabel: name, excludeFromSemantics: decorative);
    if (decorative) return image;
    return Tooltip(message: '$name (ISO 7010 ${sign.code})', child: image);
  }
}

/// A sign on a white disc, for red and amber banners: prohibition rings and
/// warning triangles stay visible on the fill (DESIGN.md, Incident banner).
class SafetySignDisc extends StatelessWidget {
  const SafetySignDisc(this.sign, {super.key, this.size = 48, this.decorative = false});

  final SafetySign sign;
  final double size;
  final bool decorative;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: SafetySignImage(sign, size: size * 0.7, decorative: decorative),
    );
  }
}

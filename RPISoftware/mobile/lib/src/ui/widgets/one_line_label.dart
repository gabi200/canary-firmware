import 'package:flutter/material.dart';

/// A button label that never wraps: at very large text sizes it shrinks to fit
/// the button instead of breaking onto a second line.
class OneLineLabel extends StatelessWidget {
  const OneLineLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text, maxLines: 1, softWrap: false),
      );
}

/// Whether every label fits on one line, at the current text size, in a
/// button [buttonWidth] wide that also holds an icon and padding ([chrome]).
/// Used to put buttons side by side only when none of them would shrink.
bool labelsFit(BuildContext context, List<String> labels, TextStyle style, double buttonWidth,
    {double chrome = 80}) {
  final scaler = MediaQuery.textScalerOf(context);
  final base = DefaultTextStyle.of(context).style.merge(style);
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: base),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    if (width + chrome > buttonWidth) return false;
  }
  return true;
}

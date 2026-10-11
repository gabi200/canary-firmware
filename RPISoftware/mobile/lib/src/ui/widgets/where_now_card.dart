import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../../models/check_in.dart';
import '../../theme.dart';
import 'safety_sign.dart';

IconData whereNowIcon(ResidentLocation where) => switch (where) {
      ResidentLocation.home => Icons.home,
      ResidentLocation.building => Icons.apartment,
      ResidentLocation.outside => Icons.park,
    };

/// "Unde ești acum?" on the alarm screen: three big answers. Once answered it
/// shows the answer with a "Schimbă" link and the [advice] that fits it.
class WhereNowCard extends StatefulWidget {
  const WhereNowCard({super.key, required this.answer, required this.advice, required this.onAnswer, this.busy = false});

  /// The resident's latest answer for this incident, or null.
  final ResidentLocation? answer;

  /// What to do for [answer].
  final String? advice;
  final void Function(ResidentLocation where) onAnswer;

  /// An answer is being sent: the buttons wait.
  final bool busy;

  @override
  State<WhereNowCard> createState() => _WhereNowCardState();
}

class _WhereNowCardState extends State<WhereNowCard> {
  /// "Schimbă" was tapped: ask again.
  bool _asking = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final blue = palette.ink(HazardColors.info);
    final answer = widget.answer;
    final asking = answer == null || _asking;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.tint(HazardColors.info, 18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: blue, width: 2),
      ),
      child: asking
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(l10n.whereNowQuestion,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: palette.text)),
                ),
                const SizedBox(height: 4),
                Text(l10n.whereNowWhy, style: TextStyle(fontSize: 15, color: palette.muted)),
                const SizedBox(height: 12),
                for (final where in ResidentLocation.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _AnswerButton(
                      where: where,
                      selected: where == answer,
                      onPressed: widget.busy
                          ? null
                          : () {
                              setState(() => _asking = false);
                              widget.onAnswer(where);
                            },
                    ),
                  ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(whereNowIcon(answer), size: 28, color: blue),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(l10n.whereYouSaid(l10n.whereNowLabel(answer)),
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: palette.text)),
                    ),
                    TextButton(
                      onPressed: widget.busy ? null : () => setState(() => _asking = true),
                      style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48), textStyle: const TextStyle(fontSize: 16)),
                      child: Text(l10n.change),
                    ),
                  ],
                ),
                if (widget.advice case final String advice) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (answer == ResidentLocation.outside) ...[
                        const SafetySignImage(SafetySign.e007, size: 32),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(advice,
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: palette.text)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

class _AnswerButton extends StatelessWidget {
  const _AnswerButton({required this.where, required this.selected, required this.onPressed});
  final ResidentLocation where;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final label = Text(context.l10n.whereNowLabel(where));
    final icon = Icon(whereNowIcon(where), size: 28);
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(60),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
    );
    return selected
        ? FilledButton.icon(style: style, onPressed: onPressed, icon: icon, label: label)
        : FilledButton.tonalIcon(style: style, onPressed: onPressed, icon: icon, label: label);
  }
}

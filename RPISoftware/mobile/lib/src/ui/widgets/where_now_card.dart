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
    final blue = palette.accentText;
    final text = Theme.of(context).textTheme;
    final answer = widget.answer;
    final asking = answer == null || _asking;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(CanaryRadius.container),
        border: Border.all(color: palette.hairlineStrong),
      ),
      child: asking
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(l10n.whereNowQuestion, style: text.headlineSmall),
                ),
                const SizedBox(height: 4),
                Text(l10n.whereNowWhy, style: text.bodyMedium!.copyWith(color: palette.textSecondary)),
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
                      child: Text(l10n.whereYouSaid(l10n.whereNowLabel(answer)), style: text.titleMedium),
                    ),
                    TextButton(
                      onPressed: widget.busy ? null : () => setState(() => _asking = true),
                      style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48), textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 16)),
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
                        child: Text(advice, style: text.titleMedium!.copyWith(fontSize: 16)),
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
    final palette = context.palette;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        foregroundColor: palette.text,
        backgroundColor: selected ? palette.tint(HazardColors.info, 40) : palette.panel,
        side: BorderSide(color: selected ? palette.accent : palette.hairlineStrong, width: selected ? 1.5 : 1),
        textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 17, fontWeight: FontWeight.w600),
      ),
      onPressed: onPressed,
      icon: Icon(whereNowIcon(where), size: 24, color: palette.accentText),
      label: Text(context.l10n.whereNowLabel(where)),
    );
  }
}

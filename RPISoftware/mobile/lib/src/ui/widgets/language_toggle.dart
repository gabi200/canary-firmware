import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../state/providers.dart';

/// Compact RO / EN switch. Segment labels are language codes and their spoken
/// names are endonyms ("Română", "English"), so they are not translated.
class LanguageToggle extends ConsumerWidget {
  const LanguageToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code = ref.watch(localeProvider).languageCode;
    return Semantics(
      container: true,
      label: context.l10n.language,
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: 'ro', label: Text('RO', semanticsLabel: 'Română'), tooltip: 'Română'),
          ButtonSegment(value: 'en', label: Text('EN', semanticsLabel: 'English'), tooltip: 'English'),
        ],
        selected: {code},
        onSelectionChanged: (selection) =>
            ref.read(localeProvider.notifier).setLanguage(selection.first),
      ),
    );
  }
}

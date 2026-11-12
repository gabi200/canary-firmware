import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../state/care_providers.dart';
import '../../theme.dart';
import '../care_profiles_screen.dart';

/// Home hint for emergency profiles: shown only once the profiles loaded and
/// are empty, until the resident dismisses it (persisted). A plain panel row:
/// the question, the action as a link, and a close button.
class CareHintCard extends ConsumerWidget {
  const CareHintCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(careHintDismissedProvider)) return const SizedBox.shrink();
    final profiles = ref.watch(careProfilesProvider).valueOrNull;
    if (profiles == null || profiles.isNotEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CareProfilesScreen())),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  hint: l10n.careHintAction,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.careProfileTitle, style: text.titleSmall),
                      const SizedBox(height: 2),
                      Text(l10n.careHintShort, style: text.bodySmall!.copyWith(color: palette.muted)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(64, 36), padding: const EdgeInsets.symmetric(horizontal: 12)),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const CareProfilesScreen())),
                child: Text(l10n.healthAdd),
              ),
              IconButton(
                icon: Icon(Icons.close, color: palette.muted, size: 20),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => ref.read(careHintDismissedProvider.notifier).dismiss(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

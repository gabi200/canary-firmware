import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../state/care_providers.dart';
import '../../theme.dart';
import '../care_profiles_screen.dart';

/// Home hint for emergency profiles: shown only once the profiles loaded and
/// are empty, until the resident dismisses it (persisted).
class CareHintCard extends ConsumerWidget {
  const CareHintCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(careHintDismissedProvider)) return const SizedBox.shrink();
    final profiles = ref.watch(careProfilesProvider).valueOrNull;
    if (profiles == null || profiles.isNotEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        margin: EdgeInsets.zero,
        color: const Color(0xFFE8F0FB),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const CareProfilesScreen())),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              children: [
                const Icon(Icons.health_and_safety, color: HazardColors.info, size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.careHintTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(l10n.careHintAction,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700, color: HazardColors.info)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => ref.read(careHintDismissedProvider.notifier).dismiss(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

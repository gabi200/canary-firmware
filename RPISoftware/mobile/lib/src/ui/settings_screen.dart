import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../state/account_providers.dart';
import '../state/providers.dart';
import 'account_screen.dart';
import 'care_profiles_screen.dart';
import 'household_screen.dart';
import 'sensor_test_screen.dart';
import 'widgets/node_commands.dart';
import 'widgets/language_toggle.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _version = '0.1.0';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final session = ref.watch(sessionProvider);
    final consent = ref.watch(consentProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settings)),
      body: ListView(
        children: [
          _SectionHeader(l10n.account),
          ListTile(
            leading: const Icon(Icons.person),
            // The hub's display name once known (updates after an edit).
            title: Text(ref.watch(meProvider).valueOrNull?.displayName ?? session?.username ?? '—'),
            subtitle: Text(
              '${session == null ? '' : l10n.roleName(session.role)} · ${session?.buildingId ?? ''}',
            ),
            trailing: Icon(Icons.edit_outlined, semanticLabel: l10n.accountEditHint),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
          ),
          const Divider(),
          _SectionHeader(l10n.language),
          ListTile(
            leading: const Icon(Icons.translate),
            // Endonym of the active language, e.g. "Română".
            title: Text(ref.watch(languageCodeProvider) == 'ro' ? 'Română' : 'English'),
            subtitle: Text(l10n.languageHint),
            trailing: const LanguageToggle(),
          ),
          const Divider(),
          _SectionHeader(l10n.appearance),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                      value: ThemeMode.system, icon: const Icon(Icons.brightness_auto), label: Text(l10n.themeAuto)),
                  ButtonSegment(value: ThemeMode.light, icon: const Icon(Icons.light_mode), label: Text(l10n.themeLight)),
                  ButtonSegment(value: ThemeMode.dark, icon: const Icon(Icons.dark_mode), label: Text(l10n.themeDark)),
                ],
                selected: {ref.watch(themeModeProvider)},
                onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(l10n.themeHint, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          const Divider(),
          if (session?.isResident ?? false)
            ListTile(
              leading: const Icon(Icons.apartment),
              title: Text(l10n.householdSettingsTitle),
              subtitle: Text(l10n.householdSettingsSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HouseholdScreen())),
            ),
          if (roleCanCommand(session?.role))
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: Text(session!.isResident ? l10n.testMySensors : l10n.testBuildingSensors),
              subtitle: Text(session.isResident ? l10n.testMySensorsSubtitle : l10n.testBuildingSensorsSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SensorTestScreen())),
            ),
          // Any role: staff get a plain "only residents" answer from the hub.
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: Text(l10n.inviteCodeEntry),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const InviteCodeEntryScreen())),
          ),
          if (session?.isResident ?? false) ...[
            const Divider(),
            _SectionHeader(l10n.careProfileTitle),
            ListTile(
              leading: const Icon(Icons.health_and_safety),
              title: Text(l10n.careProfileTitle),
              subtitle: Text(l10n.careProfileSettingsSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const CareProfilesScreen())),
            ),
          ],
          const Divider(),
          _SectionHeader(l10n.presenceContribution),
          SwitchListTile(
            title: Text(l10n.sharePresence),
            subtitle: Text(l10n.sharePresenceDetail),
            value: consent,
            onChanged: (v) => ref.read(consentProvider.notifier).set(v),
          ),
          const Divider(),
          _SectionHeader(l10n.about),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.aboutAppName),
            subtitle: Text(l10n.aboutDisclaimer(_version)),
          ),
          ListTile(
            leading: const Icon(Icons.dns),
            title: Text(l10n.server),
            subtitle: Text(ref.watch(hubProvider).url ?? ''),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              label: Text(l10n.signOut),
              onPressed: () async {
                await ref.read(sessionProvider.notifier).logout();
                if (context.mounted) Navigator.of(context).maybePop();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text.toUpperCase(),
          style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

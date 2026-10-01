import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../state/providers.dart';
import '../../l10n/gen/app_localizations.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final consent = ref.watch(consentProvider);

    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).settings)),
      body: ListView(
        children: [
          _SectionHeader(AppLocalizations.of(context).account),
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(session?.username ?? '—'),
            subtitle: Text('${session?.role ?? ''} · ${session?.buildingId ?? ''}'),
          ),
          const Divider(),
          _SectionHeader(AppLocalizations.of(context).presenceContribution),
          SwitchListTile(
            title: Text(AppLocalizations.of(context).sharePresence),
            subtitle: Text(AppLocalizations.of(context).sharePresenceDescription),
            value: consent,
            onChanged: (v) => ref.read(consentProvider.notifier).set(v),
          ),
          const Divider(),
          _SectionHeader(AppLocalizations.of(context).about),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(AppLocalizations.of(context).canaryResident),
            subtitle: Text(AppLocalizations.of(context).appVersion),
          ),
          ListTile(
            leading: const Icon(Icons.dns),
            title: Text(AppLocalizations.of(context).server),
            subtitle: const Text(Config.apiBase),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              label: Text(AppLocalizations.of(context).signOut),
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

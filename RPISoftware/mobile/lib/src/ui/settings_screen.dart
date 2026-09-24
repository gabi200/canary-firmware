import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';
import '../state/providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final consent = ref.watch(consentProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.person),
            title: Text(session?.username ?? '—'),
            subtitle: Text('${session?.role ?? ''} · ${session?.buildingId ?? ''}'),
          ),
          const Divider(),
          const _SectionHeader('Presence contribution'),
          SwitchListTile(
            title: const Text('Share my presence during incidents'),
            subtitle: const Text(
              'Lets responders better account for who is inside. Anonymous; used only during an active incident.',
            ),
            value: consent,
            onChanged: (v) => ref.read(consentProvider.notifier).set(v),
          ),
          const Divider(),
          const _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Canary resident'),
            subtitle: Text('v0.1.0 — advisory safety app. Not a substitute for certified alarms.'),
          ),
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('Server'),
            subtitle: Text(Config.apiBase),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
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

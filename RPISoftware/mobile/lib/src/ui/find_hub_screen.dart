import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../state/providers.dart';
import '../theme.dart';

/// Shown until the app has found the hub: a search in progress, or, when none was found,
/// a retry button and a field to type the hub's address.
class FindHubScreen extends ConsumerStatefulWidget {
  const FindHubScreen({super.key});
  @override
  ConsumerState<FindHubScreen> createState() => _FindHubScreenState();
}

class _FindHubScreenState extends ConsumerState<FindHubScreen> {
  final _address = TextEditingController();
  bool _busy = false;
  bool _failed = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    final ok = await ref.read(hubProvider.notifier).useManual(_address.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final searching = ref.watch(hubProvider.select((hub) => hub.searching));
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: searching
                    ? [
                        const Center(child: CircularProgressIndicator()),
                        const SizedBox(height: 16),
                        Text(l10n.hubSearching, textAlign: TextAlign.center),
                      ]
                    : [
                        Text(l10n.hubNotFound, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => ref.read(hubProvider.notifier).locate(),
                          child: Text(l10n.hubRetry),
                        ),
                        const SizedBox(height: 32),
                        TextField(
                          controller: _address,
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(labelText: l10n.hubManualLabel),
                          onSubmitted: (_) => _busy ? null : _connect(),
                        ),
                        if (_failed)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(l10n.hubManualFailed, style: TextStyle(color: context.palette.faint)),
                          ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _busy ? null : _connect,
                          child: Text(l10n.hubManualConnect),
                        ),
                      ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

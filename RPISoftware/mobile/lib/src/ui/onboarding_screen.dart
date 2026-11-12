import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../state/providers.dart';
import 'widgets/language_toggle.dart';
import '../theme.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _username = TextEditingController(text: 'ana');
  bool _busy = false;

  /// Why the last login failed, or null. Kept as the error (not text) so the
  /// message follows a language switch.
  Object? _error;

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).login(_username.text.trim());
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      // Language can be picked before signing in.
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(),
        actions: const [
          Padding(padding: EdgeInsets.only(right: 12), child: LanguageToggle()),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: context.palette.wordmarkDot, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
                    Text('Canary', style: Theme.of(context).textTheme.headlineLarge),
                  ]),
                  const SizedBox(height: 6),
                  Text(l10n.onboardingTagline,
                      style: Theme.of(context).textTheme.bodyLarge!.copyWith(color: context.palette.textSecondary)),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _username,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _busy ? null : _login(),
                    decoration: InputDecoration(labelText: l10n.username),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(l10n.demoAccount, style: Theme.of(context).textTheme.labelMedium),
                      for (final u in ['ana'])
                        ActionChip(label: Text(u), onPressed: () => _username.text = u),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(l10n.loginFailed(l10n.errorReason(_error!)),
                          style: TextStyle(color: context.palette.alarmText)),
                    ),
                  FilledButton(
                    onPressed: _busy ? null : _login,
                    child: _busy
                        ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l10n.linkMyUnit),
                  ),
                  const SizedBox(height: 12),
                  Text(l10n.serverAddress(ref.watch(hubProvider).url ?? ''),
                      style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

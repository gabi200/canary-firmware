import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../models/me.dart';
import '../services/api_client.dart';
import '../state/account_providers.dart';
import '../state/dashboard_providers.dart';
import '../theme.dart';

/// "Contul meu": name, phone and email are editable (`PATCH /me`, only changed
/// fields); username, role and apartment are read-only. For every role.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();

  /// What the hub has now; edits are compared against it.
  MeProfile? _original;

  /// 422 messages from the hub, by field, shown under that field.
  Map<String, String> _serverErrors = const {};
  String? _generalError;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  void _load(MeProfile me) {
    _original = me;
    _name.text = me.displayName ?? '';
    _phone.text = me.phone ?? '';
    _email.text = me.email ?? '';
  }

  void _edited(String field) => setState(() {
        if (_serverErrors.containsKey(field)) _serverErrors = {..._serverErrors}..remove(field);
        _generalError = null;
      });

  Future<void> _save(Map<String, String> changes) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _serverErrors = const {};
      _generalError = null;
    });
    try {
      final saved = await ref.read(meProvider.notifier).save(changes);
      if (!mounted) return;
      // Show what the hub stored (e.g. the phone normalized to +40...).
      setState(() => _load(saved));
      messenger.showSnackBar(SnackBar(content: Text(l10n.accountSaved)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        final fields = {...e.fieldErrors};
        final detail = e.detail;
        if (e.statusCode == 422 && fields.isEmpty && detail != null) {
          // A plain message: put it under the field it is about, if it says.
          final lower = detail.toLowerCase();
          final field = changes.keys.length == 1
              ? changes.keys.single
              : lower.contains('phone') || lower.contains('telefon')
                  ? 'phone'
                  : lower.contains('mail')
                      ? 'email'
                      : null;
          if (field != null) fields[field] = detail;
        }
        _serverErrors = fields;
        _generalError = fields.isEmpty ? l10n.errorReason(e) : null;
      });
    } catch (e) {
      if (mounted) setState(() => _generalError = l10n.errorReason(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(meProvider);
    final me = async.valueOrNull;
    if (me != null && _original?.userId != me.userId) _load(me);

    final Widget body;
    if (me == null) {
      body = ListView(padding: const EdgeInsets.all(16), children: [
        if (async.isLoading)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Icon(async.hasError ? Icons.sync_problem : Icons.info_outline, color: HazardColors.unknown),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(async.hasError ? l10n.accountLoadFailed : l10n.accountNotAvailable,
                      style: const TextStyle(fontSize: 16)),
                ),
                if (async.hasError)
                  TextButton(onPressed: () => ref.invalidate(meProvider), child: Text(l10n.retry)),
              ]),
            ),
          ),
      ]);
    } else {
      final original = _original!;
      final changes = AccountEdit(
        original: original,
        displayName: _name.text,
        phone: _phone.text,
        email: _email.text,
      ).changes;
      final nameError = validateDisplayName(_name.text) == null ? null : l10n.careNameRequired;
      final phoneError = validatePhone(_phone.text) == null ? null : l10n.accountPhoneInvalid;
      final emailError = validateEmail(_email.text) == null ? null : l10n.accountEmailInvalid;
      final canSave = changes.isNotEmpty && nameError == null && phoneError == null && emailError == null && !_busy;
      final units = [
        for (final u in me.units)
          if (u.kind == null || u.kind == 'residential')
            [u.unitLabel ?? prettyZone(null, u.unitId), if (u.floorLabel != null) u.floorLabel!].join(' · '),
      ];

      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            autofillHints: const [AutofillHints.name],
            inputFormatters: [LengthLimitingTextInputFormatter(80)],
            decoration: InputDecoration(
              labelText: l10n.accountName,
              prefixIcon: const Icon(Icons.person_outline),
              border: const OutlineInputBorder(),
              errorText: nameError ?? _serverErrors['display_name'],
              errorMaxLines: 3,
            ),
            onChanged: (_) => _edited('display_name'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            inputFormatters: [LengthLimitingTextInputFormatter(24)],
            decoration: InputDecoration(
              labelText: l10n.accountPhone,
              prefixIcon: const Icon(Icons.phone_outlined),
              helperText: l10n.accountPhoneHint,
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
              errorText: phoneError ?? _serverErrors['phone'],
              errorMaxLines: 3,
            ),
            onChanged: (_) => _edited('phone'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            inputFormatters: [LengthLimitingTextInputFormatter(120)],
            decoration: InputDecoration(
              labelText: l10n.accountEmail,
              prefixIcon: const Icon(Icons.email_outlined),
              border: const OutlineInputBorder(),
              errorText: emailError ?? _serverErrors['email'],
              errorMaxLines: 3,
            ),
            onChanged: (_) => _edited('email'),
          ),
          if (_generalError != null) ...[
            const SizedBox(height: 10),
            Text(_generalError!, style: const TextStyle(color: HazardColors.alarm, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: canSave ? () => _save(changes) : null,
            child: _busy
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.careSave),
          ),
          const SizedBox(height: 24),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              _ReadOnlyRow(icon: Icons.badge_outlined, label: l10n.username, value: me.username),
              _ReadOnlyRow(icon: Icons.work_outline, label: l10n.accountRole, value: l10n.roleName(me.role)),
              _ReadOnlyRow(
                icon: Icons.apartment,
                label: l10n.careUnit,
                value: units.isEmpty ? '—' : units.join('\n'),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.lock_outline, size: 16, color: context.palette.faint),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l10n.accountReadOnlyNote, style: TextStyle(fontSize: 13, color: context.palette.muted)),
            ),
          ]),
        ],
      );
    }
    return Scaffold(appBar: AppBar(title: Text(l10n.account)), body: body);
  }
}

class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label, style: TextStyle(fontSize: 13, color: context.palette.muted)),
      subtitle: Text(value, style: TextStyle(fontSize: 16, color: context.palette.text)),
    );
  }
}

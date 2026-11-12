import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n.dart';
import '../models/household.dart';
import '../services/api_client.dart';
import '../state/account_providers.dart';
import '../state/care_providers.dart';
import '../state/dashboard_providers.dart';
import '../state/household_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'invite_accept_screen.dart';
import 'widgets/one_line_label.dart';

/// "Apartamentul meu": who lives in each of the caller's units (with an
/// account), pending invites (expiry + cancel), inviting someone, leaving.
class HouseholdScreen extends ConsumerWidget {
  const HouseholdScreen({super.key});

  Future<void> _leave(BuildContext context, WidgetRef ref, HouseholdUnit unit) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final name = unit.unitLabel ?? prettyZone(null, unit.unitId);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.householdLeaveTitle(name)),
        content: Text(l10n.householdLeaveBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: HazardColors.alarm, minimumSize: const Size(88, 48)),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.householdLeaveConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).leaveUnit(unit.unitId);
      ref.invalidate(householdProvider);
      ref.invalidate(meProvider);
      ref.invalidate(careProfilesProvider);
      ref.read(summaryProvider.notifier).refresh();
      messenger.showSnackBar(SnackBar(content: Text(l10n.householdLeft)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.errorReason(e)), backgroundColor: HazardColors.alarm));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final units = ref.watch(householdProvider);
    final invites = ref.watch(pendingInvitesProvider).valueOrNull ?? const <PendingInvite>[];
    final list = units.valueOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.householdSettingsTitle)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(householdProvider);
          ref.invalidate(pendingInvitesProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (list == null && units.hasError)
              Row(children: [
                const Icon(Icons.sync_problem, color: HazardColors.warning),
                const SizedBox(width: 8),
                Expanded(child: Text(l10n.householdLoadFailed)),
                TextButton(onPressed: () => ref.invalidate(householdProvider), child: Text(l10n.retry)),
              ])
            else if (list == null)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
            else if (list.isEmpty)
              Text(l10n.householdEmpty, style: const TextStyle(fontSize: 16))
            else
              for (final unit in list) ...[
                _UnitCard(
                  unit: unit,
                  invites: invites.where((i) => i.unitId == unit.unitId).toList(),
                  onInvite: () => inviteToUnit(context, ref, unitId: unit.unitId, unitLabel: unit.unitLabel),
                  onLeave: () => _leave(context, ref, unit),
                ),
                const SizedBox(height: 16),
              ],
          ],
        ),
      ),
    );
  }
}

class _UnitCard extends ConsumerWidget {
  const _UnitCard({required this.unit, required this.invites, required this.onInvite, required this.onLeave});
  final HouseholdUnit unit;
  final List<PendingInvite> invites;
  final VoidCallback onInvite;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.apartment, color: HazardColors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(unit.unitLabel ?? prettyZone(null, unit.unitId),
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 10),
            Text(l10n.householdMembers, style: TextStyle(fontWeight: FontWeight.w700, color: context.palette.muted)),
            for (final m in unit.members)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(m.isMe ? Icons.person : Icons.person_outline),
                title: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(m.displayName, style: const TextStyle(fontSize: 16)),
                  if (m.isMe)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: HazardColors.info.withAlpha(30),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(l10n.careSelfBadge,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: HazardColors.info)),
                    ),
                ]),
                subtitle: m.since == null ? null : Text(l10n.householdMemberSince(l10n.clockTime(m.since!))),
              ),
            if (invites.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(l10n.householdPendingInvites,
                  style: TextStyle(fontWeight: FontWeight.w700, color: context.palette.muted)),
              for (final i in invites)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.mail_outline),
                  title:
                      Text(i.careProfileName == null ? l10n.inviteTitle : l10n.householdInviteFor(i.careProfileName!)),
                  subtitle: i.expiresTs == null ? null : Text(l10n.householdExpires(l10n.clockTime(i.expiresTs!))),
                  trailing: IconButton(
                    tooltip: l10n.householdRevoke,
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await ref.read(apiClientProvider).revokeInvite(i.id);
                        ref.invalidate(pendingInvitesProvider);
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text(l10n.errorReason(e))));
                      }
                    },
                  ),
                ),
            ],
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.person_add_alt),
              label: OneLineLabel(l10n.householdInviteSomeone),
              onPressed: onInvite,
            ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: HazardColors.alarm, minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.logout),
              label: OneLineLabel(l10n.householdLeave),
              onPressed: onLeave,
            ),
          ],
        ),
      ),
    );
  }
}

/// Creates an invite for [unitId] (optionally tied to a household member's
/// care profile, which the invitee may take over) and shows the share sheet.
Future<void> inviteToUnit(BuildContext context, WidgetRef ref,
    {required String unitId, String? unitLabel, String? careProfileId}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final invite = await ref.read(apiClientProvider).createInvite(unitId: unitId, careProfileId: careProfileId);
    ref.invalidate(pendingInvitesProvider);
    if (!context.mounted) return;
    await showInviteSheet(context, invite, unitLabel: unitLabel);
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text(e.statusCode == 409 ? l10n.householdTooManyInvites : l10n.errorReason(e)),
      backgroundColor: HazardColors.alarm,
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(l10n.errorReason(e)), backgroundColor: HazardColors.alarm));
  }
}

/// The link, Copy / SMS / email, and "expires in N hours, single use".
Future<void> showInviteSheet(BuildContext context, CreatedInvite invite, {String? unitLabel}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) {
      final l10n = sheet.l10n;
      final unit = invite.unitLabel ?? unitLabel ?? prettyZone(null, invite.unitId);
      final message = l10n.inviteMessage(unit, invite.url);
      final expires = invite.expiresTs;
      final hours = expires == null ? null : (expires.difference(DateTime.now()).inMinutes / 60).ceil().clamp(1, 9999);
      Future<void> open(Uri uri) async {
        try {
          await launchUrl(uri);
        } catch (_) {
          // No SMS / mail app: the link can still be copied.
        }
      }

      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          children: [
            Text(l10n.inviteSheetTitle, style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: context.palette.well, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(invite.url, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            if (hours != null) ...[
              const SizedBox(height: 8),
              Text(l10n.inviteExpiryHours(hours), style: TextStyle(color: context.palette.muted)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.copy),
              label: OneLineLabel(l10n.inviteCopy),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(sheet);
                await Clipboard.setData(ClipboardData(text: invite.url));
                messenger.showSnackBar(SnackBar(content: Text(l10n.inviteCopied)));
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.sms_outlined),
              label: OneLineLabel(l10n.inviteSms),
              // %20, not '+': Messages / mail apps show '+' literally.
              onPressed: () => open(Uri.parse('sms:?body=${Uri.encodeComponent(message)}')),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.email_outlined),
              label: OneLineLabel(l10n.inviteEmail),
              onPressed: () => open(Uri.parse(
                  'mailto:?subject=${Uri.encodeComponent(l10n.inviteEmailSubject)}&body=${Uri.encodeComponent(message)}')),
            ),
          ],
        ),
      );
    },
  );
}

/// "Am un cod de invitație": paste a code or a whole link.
class InviteCodeEntryScreen extends StatefulWidget {
  const InviteCodeEntryScreen({super.key});

  @override
  State<InviteCodeEntryScreen> createState() => _InviteCodeEntryScreenState();
}

class _InviteCodeEntryScreenState extends State<InviteCodeEntryScreen> {
  final _input = TextEditingController();
  bool _tried = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _continue() {
    final code = extractInviteCode(_input.text);
    setState(() => _tried = true);
    if (code == null) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => InviteAcceptScreen(code: code)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final invalid = _tried && extractInviteCode(_input.text) == null;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.inviteCodeEntry)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _input,
            autofocus: true,
            autocorrect: false,
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              labelText: l10n.inviteCodeLabel,
              hintText: l10n.inviteCodeHint,
              border: const OutlineInputBorder(),
              errorText: invalid ? l10n.inviteCodeInvalid : null,
              suffixIcon: IconButton(
                tooltip: MaterialLocalizations.of(context).pasteButtonLabel,
                icon: const Icon(Icons.content_paste),
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) setState(() => _input.text = data!.text!);
                },
              ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _continue(),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _input.text.trim().isEmpty ? null : _continue, child: Text(l10n.inviteContinue)),
        ],
      ),
    );
  }
}

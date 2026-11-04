import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../models/household.dart';
import '../state/account_providers.dart';
import '../state/care_providers.dart';
import '../state/dashboard_providers.dart';
import '../state/household_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'onboarding_screen.dart';

/// Route target of a deep link (`/join/<code>` or `canary://join/<code>`):
/// signed out, it shows the sign-in screen and keeps the code; once signed
/// in, the accept screen.
class InviteGate extends ConsumerWidget {
  const InviteGate({super.key, required this.code});
  final String code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(sessionProvider) != null) return InviteAcceptScreen(code: code);
    return Stack(children: [
      const OnboardingScreen(),
      Positioned(
        left: 16,
        right: 16,
        bottom: 16,
        child: SafeArea(
          child: Material(
            color: const Color(0xFFE8F0FB),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                const Icon(Icons.mail_outline, color: HazardColors.info),
                const SizedBox(width: 10),
                Expanded(child: Text(context.l10n.inviteLoginFirst, style: const TextStyle(fontSize: 15))),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Preview of an invite (who, building, apartment, floor, expiry), the
/// optional take-over of a care profile created for the invitee (separate,
/// unticked consent), and Accept / Decline.
class InviteAcceptScreen extends ConsumerStatefulWidget {
  const InviteAcceptScreen({super.key, required this.code});
  final String code;

  @override
  ConsumerState<InviteAcceptScreen> createState() => _InviteAcceptScreenState();
}

class _InviteAcceptScreenState extends ConsumerState<InviteAcceptScreen> {
  late Future<InvitePreview> _preview = ref.read(apiClientProvider).invitePreview(widget.code);
  bool _takeOver = false;
  bool _consent = false;
  bool _busy = false;
  String? _error;

  Future<void> _accept(InvitePreview preview) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final takeOver = preview.hasCareProfile && _takeOver;
      final result = await ref
          .read(apiClientProvider)
          .acceptInvite(widget.code, takeOverCareProfile: takeOver, consent: takeOver && _consent);
      // The session building follows the hub's mode, not the invite's building.
      ref.invalidate(meProvider);
      ref.invalidate(careProfilesProvider);
      ref.invalidate(householdProvider);
      ref.invalidate(zonesInfoProvider);
      ref.read(summaryProvider.notifier).refresh();
      navigator.popUntil((route) => route.isFirst);
      messenger.showSnackBar(SnackBar(content: Text(l10n.inviteAccepted(result.unitLabel ?? preview.unitLabel ?? ''))));
    } catch (e) {
      if (mounted) setState(() => _error = l10n.inviteError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.inviteTitle)),
      body: FutureBuilder<InvitePreview>(
        future: _preview,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(l10n.inviteLoading),
              ]),
            );
          }
          if (snap.hasError) {
            return ListView(padding: const EdgeInsets.all(16), children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.link_off, color: HazardColors.alarm),
                const SizedBox(width: 10),
                Expanded(child: Text(l10n.inviteError(snap.error!), style: const TextStyle(fontSize: 17))),
              ]),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => setState(() => _preview = ref.read(apiClientProvider).invitePreview(widget.code)),
                child: Text(l10n.retry),
              ),
            ]);
          }
          final p = snap.data!;
          final inviter = p.inviterName ?? '—';
          final canAccept = !_busy && !(p.hasCareProfile && _takeOver && !_consent);
          Widget row(IconData icon, String label, String? value) => value == null
              ? const SizedBox.shrink()
              : ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(icon),
                  title: Text(label, style: TextStyle(fontSize: 13, color: context.palette.muted)),
                  subtitle: Text(value, style: TextStyle(fontSize: 17, color: context.palette.text)),
                );
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text(l10n.inviteFrom(inviter), style: const TextStyle(fontSize: 18)),
              Text(p.unitLabel ?? '—', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              row(Icons.location_city, l10n.inviteBuilding, p.buildingName),
              row(Icons.apartment, l10n.careUnit, p.unitLabel),
              row(Icons.stairs_outlined, l10n.inviteFloor, p.floorLabel),
              if (p.expiresTs != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: Text(l10n.householdExpires(l10n.clockTime(p.expiresTs!))),
                ),
              if (p.hasCareProfile) ...[
                const SizedBox(height: 8),
                Material(
                  // A Material (not a decorated box) so the checkbox tiles' ink shows.
                  color: const Color(0xFFEFF4FB),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Icon(Icons.health_and_safety, color: HazardColors.info),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(l10n.inviteCareOffer(inviter, p.careProfileName ?? '—'),
                              style: const TextStyle(fontSize: 16)),
                        ),
                      ]),
                      // Taking over is optional; its consent is separate and unticked.
                      CheckboxListTile(
                        value: _takeOver,
                        onChanged: (v) => setState(() {
                          _takeOver = v ?? false;
                          if (!_takeOver) _consent = false;
                        }),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.inviteTakeOver, style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      if (_takeOver)
                        CheckboxListTile(
                          value: _consent,
                          onChanged: (v) => setState(() => _consent = v ?? false),
                          controlAffinity: ListTileControlAffinity.leading,
                          contentPadding: EdgeInsets.zero,
                          title: Text(l10n.careConsent, style: const TextStyle(fontSize: 15, height: 1.3)),
                        ),
                      if (_takeOver && !_consent)
                        Text(l10n.inviteNeedsConsent, style: TextStyle(color: context.palette.muted)),
                    ]),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: HazardColors.alarm, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: canAccept ? () => _accept(p) : null,
                child: _busy
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l10n.inviteAccept),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
                child: Text(l10n.inviteDecline),
              ),
            ],
          );
        },
      ),
    );
  }
}

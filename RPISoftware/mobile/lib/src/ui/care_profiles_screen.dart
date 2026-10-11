import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../logic/health_suggestions.dart';
import '../models/care_profile.dart';
import '../services/api_client.dart';
import '../state/care_providers.dart';
import '../state/dashboard_providers.dart';
import '../theme.dart';
import 'household_screen.dart';
import 'widgets/one_line_label.dart';

IconData careNeedIcon(CareNeed need) => switch (need) {
      CareNeed.reducedMobility => Icons.elderly,
      CareNeed.wheelchair => Icons.accessible,
      CareNeed.bedridden => Icons.bed,
      CareNeed.hearingImpaired => Icons.hearing_disabled,
      CareNeed.visuallyImpaired => Icons.visibility_off,
      CareNeed.medicalDevice => Icons.medical_services,
      CareNeed.youngChild => Icons.child_care,
      CareNeed.pet => Icons.pets,
    };

bool _notActive(Object? error) => error is ApiException && error.statusCode == 503;

/// "Profil de urgență": the resident's own profile and household members'.
class CareProfilesScreen extends ConsumerWidget {
  const CareProfilesScreen({super.key});

  void _open(BuildContext context, [CareProfile? profile]) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CareProfileFormScreen(existing: profile)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(careProfilesProvider);
    final profiles = async.valueOrNull;
    final List<Widget> content;
    if (profiles == null && async.hasError) {
      content = [
        _Notice(
          icon: _notActive(async.error) ? Icons.info_outline : Icons.sync_problem,
          text: _notActive(async.error) ? l10n.careNotActive : l10n.careLoadFailed,
          action: _notActive(async.error)
              ? null
              : TextButton(onPressed: () => ref.read(careProfilesProvider.notifier).refresh(), child: Text(l10n.retry)),
        ),
      ];
    } else if (profiles == null) {
      content = const [Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))];
    } else {
      content = [
        if (profiles.isEmpty) ...[
          const Icon(Icons.health_and_safety, size: 56, color: HazardColors.info),
          const SizedBox(height: 12),
          Text(l10n.careEmptyBody, style: const TextStyle(fontSize: 17, height: 1.35)),
          const SizedBox(height: 20),
        ] else ...[
          // The resident first, then household members.
          for (final p in [...profiles.where((p) => p.isSelf), ...profiles.where((p) => !p.isSelf)]) ...[
            _ProfileCard(profile: p, onTap: () => _open(context, p)),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 6),
        ],
        FilledButton.icon(
          icon: const Icon(Icons.add),
          label: Text(l10n.careAddPerson),
          onPressed: () => _open(context),
        ),
      ];
    }
    return Scaffold(
      appBar: AppBar(title: Text(l10n.careProfileTitle)),
      body: RefreshIndicator(
        onRefresh: () => ref.read(careProfilesProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            ...content,
            const SizedBox(height: 20),
            _PrivacyNote(text: l10n.carePrivacyNote),
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.onTap});
  final CareProfile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = profile;
    final unit = p.unitLabel ?? prettyZone(null, p.unitId);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(p.isSelf ? Icons.person : Icons.family_restroom, size: 28, color: HazardColors.info),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(p.displayName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        if (p.isSelf)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: HazardColors.info.withAlpha(30),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(l10n.careSelfBadge,
                                style: const TextStyle(fontWeight: FontWeight.w700, color: HazardColors.info)),
                          ),
                      ],
                    ),
                    Text(unit, style: TextStyle(color: context.palette.muted)),
                    if (p.needs.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final n in p.needs)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1F3F5),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(careNeedIcon(n), size: 16, color: context.palette.muted),
                                const SizedBox(width: 4),
                                Flexible(child: Text(l10n.careNeed(n))),
                              ]),
                            ),
                        ],
                      ),
                    ],
                    if (p.note != null) ...[
                      const SizedBox(height: 6),
                      Text(p.note!, style: TextStyle(fontStyle: FontStyle.italic, color: context.palette.text)),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: context.palette.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// Add / edit one profile. Saving needs explicit consent each time, a name, the
/// unit, and at least one need or a note.
class CareProfileFormScreen extends ConsumerStatefulWidget {
  const CareProfileFormScreen({super.key, this.existing, this.initialSelf = false, this.autoImportHealth = false});
  final CareProfile? existing;

  /// Start on "Pentru mine" (new profiles only).
  final bool initialSelf;

  /// Start the Apple Health import right away (QA aid; see Config.startRoute).
  final bool autoImportHealth;

  @override
  ConsumerState<CareProfileFormScreen> createState() => _CareProfileFormScreenState();
}

class _CareProfileFormScreenState extends ConsumerState<CareProfileFormScreen> {
  late bool _isSelf;
  late final TextEditingController _name;
  late final TextEditingController _note;
  late Set<CareNeed> _needs;
  String? _unitId;

  /// Consent is never pre-ticked, also when editing: each save is a fresh,
  /// explicit agreement.
  bool _consent = false;
  bool _nameEdited = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    final selfTaken = (ref.read(careProfilesProvider).valueOrNull ?? const []).any((x) => x.isSelf);
    // Household members are the main use; "for me" is one tap away when free.
    _isSelf = p?.isSelf ?? widget.initialSelf;
    _name = TextEditingController(text: p?.displayName ?? '');
    _note = TextEditingController(text: p?.note ?? '');
    _needs = {...?p?.needs};
    _unitId = p?.unitId;
    _nameEdited = p != null;
    if (p == null && selfTaken) _isSelf = false;
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _setSelf(bool self, MyHousehold? household) {
    setState(() {
      _isSelf = self;
      if (!_nameEdited) _name.text = self ? (household?.displayName ?? '') : '';
    });
  }

  Future<void> _save(String unitId) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(careProfilesProvider.notifier).save(
            CareProfileDraft(
              unitId: unitId,
              displayName: _name.text,
              isSelf: _isSelf,
              needs: _needs,
              note: _note.text,
              consent: _consent,
            ),
            id: widget.existing?.id,
          );
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(l10n.careSaved)));
    } catch (e) {
      if (mounted) setState(() => _error = l10n.careError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.careDeleteConfirmTitle),
        content: Text(l10n.careDeleteConfirmBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: HazardColors.alarm, minimumSize: const Size(88, 48)),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(careProfilesProvider.notifier).delete(widget.existing!.id);
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(l10n.careDeleted)));
    } catch (e) {
      if (mounted) setState(() => _error = l10n.careError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final existing = widget.existing;
    final household = ref.watch(myHouseholdProvider);
    final units = household.valueOrNull?.units;
    final profiles = ref.watch(careProfilesProvider).valueOrNull ?? const <CareProfile>[];
    final selfTaken = profiles.any((p) => p.isSelf && p.id != existing?.id);
    final unitId = _unitId ?? ((units?.isNotEmpty ?? false) ? units!.first.id : null);
    final ready = careDraftReady(
      name: _name.text,
      needs: _needs,
      note: _note.text,
      consent: _consent,
      unitId: unitId,
    );

    return Scaffold(
      appBar: AppBar(title: Text(existing == null ? l10n.careNewTitle : l10n.careEditTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: true, label: Text(l10n.careForMe), enabled: !selfTaken),
                ButtonSegment(value: false, label: Text(l10n.careForOther)),
              ],
              selected: {_isSelf},
              onSelectionChanged: (s) => _setSelf(s.first, household.valueOrNull),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            inputFormatters: [LengthLimitingTextInputFormatter(80)],
            decoration: InputDecoration(
              labelText: l10n.careName,
              border: const OutlineInputBorder(),
              errorText: _nameEdited && _name.text.trim().isEmpty ? l10n.careNameRequired : null,
            ),
            onChanged: (_) => setState(() => _nameEdited = true),
          ),
          if (units != null && units.length > 1) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: unitId,
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.careUnit, border: const OutlineInputBorder()),
              items: [
                for (final u in units) DropdownMenuItem(value: u.id, child: Text(u.label ?? prettyZone(null, u.id))),
              ],
              onChanged: (v) => setState(() => _unitId = v),
            ),
          ],
          if (household.isLoading && units == null) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          if (unitId == null && !household.isLoading) ...[
            const SizedBox(height: 8),
            Text(l10n.careNoUnit, style: const TextStyle(color: HazardColors.alarm)),
          ],
          // Apple Health suggestions: iOS, own profile only; never auto-applied.
          if (_isSelf) ...[
            const SizedBox(height: 16),
            HealthImportPanel(
              autoStart: widget.autoImportHealth,
              selected: _needs,
              onToggle: (need, add) => setState(() => add ? _needs.add(need) : _needs.remove(need)),
            ),
          ],
          const SizedBox(height: 20),
          Text(l10n.careNeedsLabel, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          NeedsPicker(
            selected: _needs,
            onToggle: (n) => setState(() => _needs.contains(n) ? _needs.remove(n) : _needs.add(n)),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _note,
            maxLength: careNoteMaxLength,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: l10n.careNote,
              hintText: l10n.careNoteHint,
              hintMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          // Separate, explicit consent for health data (GDPR art. 9): never pre-ticked.
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: _consent ? HazardColors.normal : context.palette.divider, width: 1.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: CheckboxListTile(
              value: _consent,
              onChanged: (v) => setState(() => _consent = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
              title: Text(l10n.careConsent, style: const TextStyle(fontSize: 15, height: 1.3)),
            ),
          ),
          const SizedBox(height: 12),
          if (!ready) Text(l10n.careSaveHint, style: TextStyle(color: context.palette.muted)),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: HazardColors.alarm, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: ready && !_busy ? () => _save(unitId!) : null,
            child: _busy
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.careSave),
          ),
          // A household member who has (or will make) their own account.
          if (existing != null && !existing.isSelf) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.person_add_alt),
              label: OneLineLabel(l10n.careInviteMember),
              onPressed: _busy
                  ? null
                  : () => inviteToUnit(context, ref,
                      unitId: existing.unitId, unitLabel: existing.unitLabel, careProfileId: existing.id),
            ),
          ],
          if (existing != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: HazardColors.alarm, minimumSize: const Size.fromHeight(48)),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.careDelete),
              onPressed: _busy ? null : _delete,
            ),
          ],
          const SizedBox(height: 16),
          _PrivacyNote(text: l10n.carePrivacyNote),
        ],
      ),
    );
  }
}

/// "Import from Health (Apple)": reads wheelchair use, walking steadiness and
/// the latest audiogram once, and lists the needs they suggest, each with an
/// Add switch (off until the user turns it on). The reading stays in this
/// widget's memory only; hidden where HealthKit doesn't exist.
class HealthImportPanel extends ConsumerStatefulWidget {
  const HealthImportPanel({super.key, required this.selected, required this.onToggle, this.autoStart = false});
  final Set<CareNeed> selected;
  final bool autoStart;
  final void Function(CareNeed need, bool add) onToggle;

  @override
  ConsumerState<HealthImportPanel> createState() => _HealthImportPanelState();
}

class _HealthImportPanelState extends ConsumerState<HealthImportPanel> {
  bool _loading = false;
  HealthReading? _reading;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart && ref.read(healthImportProvider).supported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _import();
      });
    }
  }

  Future<void> _import() async {
    setState(() {
      _loading = true;
      _failed = false;
      _reading = null;
    });
    try {
      final reading = await ref.read(healthImportProvider).read();
      if (mounted) setState(() => _reading = reading);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _source(AppLocalizations l10n, HealthSuggestion s) => switch (s.source) {
        HealthSource.profile => l10n.healthFromProfile,
        HealthSource.walkingSteadiness => l10n.healthFromSteadiness(l10n.count((s.value ?? 0).round())),
        HealthSource.audiogram => l10n.healthFromAudiogram(l10n.count((s.value ?? 0).round())),
      };

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(healthImportProvider).supported) return const SizedBox.shrink();
    final l10n = context.l10n;
    final reading = _reading;
    final suggestions = reading == null || !reading.available ? const <HealthSuggestion>[] : healthSuggestions(reading);

    Widget note(IconData icon, String text, [String? detail]) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: HazardColors.unknown),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                if (detail != null) Text(detail, style: TextStyle(fontSize: 13, color: context.palette.muted)),
              ]),
            ),
          ]),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          icon: const Icon(Icons.monitor_heart_outlined),
          label: OneLineLabel(l10n.healthImportButton),
          onPressed: _loading ? null : _import,
        ),
        if (_loading)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(children: [
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.healthImporting)),
            ]),
          ),
        if (_failed) note(Icons.sync_problem, l10n.healthReadFailed, l10n.healthAccessNote),
        if (reading != null && !reading.available) note(Icons.info_outline, l10n.healthUnavailable),
        if (reading != null && reading.available && suggestions.isEmpty)
          note(Icons.search_off, l10n.healthNothingFound, l10n.healthAccessNote),
        if (suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            // A Material (not a decorated box) so the switch tiles' ink shows.
            child: Material(
              color: context.palette.tile,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFFDADCE0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child:
                        Text(l10n.healthFoundTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  for (final s in suggestions)
                    Semantics(
                      label: l10n.healthSuggestionSemantics(l10n.careNeed(s.need), _source(l10n, s)),
                      toggled: widget.selected.contains(s.need),
                      excludeSemantics: true,
                      child: SwitchListTile(
                        secondary: Icon(careNeedIcon(s.need), color: HazardColors.info),
                        title: Text('${l10n.careNeed(s.need)} — ${_source(l10n, s)}'),
                        subtitle: Text(l10n.healthAdd),
                        value: widget.selected.contains(s.need),
                        onChanged: (v) => widget.onToggle(s.need, v),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(l10n.healthPrivacy, style: TextStyle(fontSize: 12, color: context.palette.muted)),
        ),
      ],
    );
  }
}

/// Big two-column toggles for the needs (multi-select), icon + words.
class NeedsPicker extends StatelessWidget {
  const NeedsPicker({super.key, required this.selected, required this.onToggle});
  final Set<CareNeed> selected;
  final ValueChanged<CareNeed> onToggle;

  @override
  Widget build(BuildContext context) {
    const needs = CareNeed.values;
    return Column(
      children: [
        for (var i = 0; i < needs.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _NeedToggle(need: needs[i], selected: selected.contains(needs[i]), onTap: onToggle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: i + 1 < needs.length
                        ? _NeedToggle(need: needs[i + 1], selected: selected.contains(needs[i + 1]), onTap: onToggle)
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _NeedToggle extends StatelessWidget {
  const _NeedToggle({required this.need, required this.selected, required this.onTap});
  final CareNeed need;
  final bool selected;
  final ValueChanged<CareNeed> onTap;

  @override
  Widget build(BuildContext context) {
    final label = context.l10n.careNeed(need);
    final color = selected ? HazardColors.info : context.palette.text;
    return Semantics(
      button: true,
      checked: selected,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: selected ? HazardColors.info.withAlpha(28) : context.palette.tile,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? HazardColors.info : const Color(0xFFDADCE0), width: selected ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onTap(need),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(careNeedIcon(need), size: 26, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: color)),
                  ),
                  if (selected) const Icon(Icons.check_circle, size: 20, color: HazardColors.info),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(icon, color: HazardColors.unknown),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 16))),
          if (action != null) action!,
        ]),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 16, color: context.palette.faint),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: context.palette.muted))),
      ],
    );
  }
}

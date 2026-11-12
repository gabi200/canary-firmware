import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../logic/unit_scope.dart';
import '../../state/scope_providers.dart';
import '../../theme.dart';
import 'status_hero.dart';

/// The apartment picker pinned at the top of a sensor list (a sliver): one
/// chip per apartment, then the common areas and "Toată clădirea"; with a
/// unit of several rooms picked, a second row "Toate camerele" + its rooms.
/// Each chip shows its sensor count and the worst sensor status as a dot.
class UnitScopeHeader extends StatelessWidget {
  const UnitScopeHeader({super.key, required this.scope});
  final SensorScope scope;

  @override
  Widget build(BuildContext context) {
    final extent = UnitScopeBar.heightFor(context, rows: scope.showsRooms ? 2 : 1);
    return SliverPersistentHeader(pinned: true, delegate: _ScopeHeaderDelegate(scope: scope, extent: extent));
  }
}

class _ScopeHeaderDelegate extends SliverPersistentHeaderDelegate {
  _ScopeHeaderDelegate({required this.scope, required this.extent});
  final SensorScope scope;
  final double extent;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) =>
      UnitScopeBar(scope: scope, raised: overlapsContent || shrinkOffset > 0);

  @override
  bool shouldRebuild(_ScopeHeaderDelegate old) => old.scope != scope || old.extent != extent;
}

class UnitScopeBar extends ConsumerWidget {
  const UnitScopeBar({super.key, required this.scope, this.raised = false});
  final SensorScope scope;

  /// The list scrolls under it: a shadow sets it apart.
  final bool raised;

  static const _pad = 8.0;
  static const _gap = 6.0;
  static const _labelSize = 16.0;

  /// One chip row, tall enough for the chip at the user's text size.
  static double rowHeight(BuildContext context) =>
      math.max(52, MediaQuery.textScalerOf(context).scale(_labelSize) * 1.4 + 22);

  static double heightFor(BuildContext context, {required int rows}) =>
      _pad * 2 + rows * rowHeight(context) + (rows - 1) * _gap + 1;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final choose = ref.read(scopeChoiceProvider.notifier);
    final unit = scope.unit;
    final room = scope.room;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: raised ? 3 : 0,
      child: Column(
        children: [
          const SizedBox(height: _pad),
          _ChipRow(
            label: l10n.scopePickUnit,
            selected: unit == null ? scope.units.length : scope.units.indexOf(unit),
            chips: [
              for (final u in scope.units)
                _ScopeChip(
                  label: u.label,
                  count: u.sensorCount,
                  status: u.status,
                  selected: unit?.id == u.id,
                  onTap: () => choose.set(ScopeChoice(unitId: u.id)),
                ),
              _ScopeChip(
                label: scope.staff ? l10n.scopeWholeBuilding : l10n.scopeAllHomes,
                count: scope.sensorCount,
                status: scope.status,
                selected: unit == null,
                onTap: () => choose.set(const ScopeChoice.wholeBuilding()),
              ),
            ],
          ),
          if (scope.showsRooms && unit != null) ...[
            const SizedBox(height: _gap),
            _ChipRow(
              // A new row per unit, starting at its own selection.
              key: ValueKey(unit.id),
              label: l10n.scopePickRoom,
              selected: room == null ? 0 : unit.rooms.indexOf(room) + 1,
              chips: [
                _ScopeChip(
                  label: l10n.scopeAllRooms,
                  count: unit.sensorCount,
                  status: unit.status,
                  selected: room == null,
                  onTap: () => choose.set(ScopeChoice(unitId: unit.id)),
                ),
                for (final r in unit.rooms)
                  _ScopeChip(
                    label: r.label,
                    count: r.nodes.length,
                    status: r.status,
                    selected: room?.zoneId == r.zoneId,
                    onTap: () => choose.set(ScopeChoice(unitId: unit.id, zoneId: r.zoneId)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: _pad),
          Divider(height: 1, thickness: 1, color: context.palette.divider),
        ],
      ),
    );
  }
}

/// A horizontally scrolling row of chips; the selected one is scrolled into
/// view when the row first shows.
class _ChipRow extends StatefulWidget {
  const _ChipRow({super.key, required this.label, required this.chips, required this.selected});
  final String label;
  final List<Widget> chips;
  final int selected;

  @override
  State<_ChipRow> createState() => _ChipRowState();
}

class _ChipRowState extends State<_ChipRow> {
  final _controller = ScrollController();
  final _selectedKey = GlobalKey();

  /// The chip selected when the row first showed (keeps its key, so it never
  /// moves between chips).
  late final int _initial = widget.selected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chip = _selectedKey.currentContext?.findRenderObject();
      // Only this row scrolls, never the list around it.
      if (mounted && chip != null && _controller.hasClients) _controller.position.ensureVisible(chip, alignment: 0.5);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: UnitScopeBar.rowHeight(context),
      child: Semantics(
        container: true,
        label: widget.label,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (var i = 0; i < widget.chips.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                KeyedSubtree(key: i == _initial ? _selectedKey : null, child: widget.chips[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.label,
    required this.count,
    required this.status,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final int count;
  final String status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final flagged = status == 'attention' || status == 'danger';
    return ChoiceChip(
      showCheckmark: false,
      selected: selected,
      onSelected: (_) => onTap(),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      labelPadding: const EdgeInsets.only(left: 4, right: 2),
      backgroundColor: context.palette.panel,
      selectedColor: context.palette.tint(HazardColors.info, 34),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CanaryRadius.control)),
      side: BorderSide(color: selected ? scheme.primary : context.palette.hairlineStrong, width: selected ? 1.5 : 1),
      // A state mark (dot / square / triangle), so state is not told by colour alone.
      avatar: StateMark(color: HazardColors.forLevel(status), size: flagged ? 11 : 9),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            semanticsLabel: [label, l10n.sensorCount(count), l10n.statusLabel(status)].join(', '),
            style: TextStyle(
              fontSize: UnitScopeBar._labelSize,
              height: 1.2,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: context.palette.text,
            ),
          ),
          const SizedBox(width: 8),
          ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: context.palette.raised,
                borderRadius: BorderRadius.circular(CanaryRadius.tag),
              ),
              child: Text(
                l10n.count(count),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: context.palette.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

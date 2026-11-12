import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n.dart';
import '../../logic/node_commands.dart';
import '../../models/care_profile.dart';
import '../../models/node_command.dart';
import '../../models/summary.dart';
import '../../models/zone_info.dart';
import '../../state/account_providers.dart';
import '../../state/command_controller.dart';
import '../../state/dashboard_providers.dart';
import '../../state/providers.dart';
import '../../theme.dart';

// "Testează senzorul": the test buttons for one sensor (air: 4-second alarm
// test + silence; water: close / open the valve + silence), the live result
// of the last press and the hub's "Ultimul test" line.

const _amberText = HazardColors.warning; // drawn through palette.ink as text

/// What the signed-in user may do with [node]'s commands (role, zone, own units).
CommandAccess commandAccessFor(WidgetRef ref, NodeAnalysis node) {
  final role = ref.watch(sessionProvider)?.role;
  if (role != 'resident') return commandAccess(role: role, zone: null);
  final zones = ref.watch(zonesInfoProvider).valueOrNull ?? const <ZoneInfo>[];
  final zone = zones.where((z) => z.id == node.zoneId).firstOrNull;
  final own = {for (final u in ref.watch(meProvider).valueOrNull?.residentialUnits ?? const <UnitRef>[]) u.id};
  return commandAccess(role: role, zone: zone, ownUnitIds: own);
}

/// May this role send commands at all (managers, admins, residents)?
bool roleCanCommand(String? role) => role == 'resident' || role == 'hoa_manager' || role == 'system_admin';

/// "Ultimul test: reușit · acum 2 min" / "Netestat", with a small status icon.
class LastTestLine extends StatelessWidget {
  const LastTestLine({super.key, required this.command, this.showWho = false, this.fontSize = 13});
  final NodeCommand? command;

  /// Adds who sent it (managers' list).
  final bool showWho;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = command;
    final (icon, color) = switch (c?.status) {
      null => (Icons.radio_button_unchecked, HazardColors.unknown),
      CommandStatus.accepted => (Icons.check_circle, HazardColors.normal),
      CommandStatus.rejected => (Icons.warning_amber_rounded, _amberText),
      CommandStatus.timeout => (Icons.help_outline, HazardColors.unknown),
      CommandStatus.sent => (Icons.schedule, HazardColors.unknown),
    };
    final who = showWho ? c?.requestedByName : null;
    final text = [l10n.lastTestText(c), if (who != null) who].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: fontSize + 3, color: color),
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(fontSize: fontSize, color: context.palette.muted))),
      ],
    );
  }
}

/// The test section of one sensor. Hidden for sensors the user can't command;
/// a resident looking at a common area gets a one-line note instead.
class NodeCommandPanel extends ConsumerWidget {
  const NodeCommandPanel({super.key, required this.node, this.showTitle = true, this.showWho = false, this.topGap = 0});
  final NodeAnalysis node;
  final bool showTitle;
  final bool showWho;

  /// Space above, only when the panel shows anything.
  final double topGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = commandAccessFor(ref, node);
    if (access == CommandAccess.none || NodeCommandType.forKind(node.kind).isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final children = <Widget>[
      if (topGap > 0) SizedBox(height: topGap),
      if (showTitle) ...[
        Text(l10n.testSectionTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
      ],
      LastTestLine(command: node.lastCommand, showWho: showWho),
    ];
    if (access == CommandAccess.commonArea) {
      children.addAll([
        const SizedBox(height: 8),
        _Note(icon: Icons.lock_outline, text: l10n.commonAreaTestNote),
      ]);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    }

    final run = ref.watch(nodeCommandsProvider.select((runs) => runs[node.nodeId]));
    final enabled = node.online && !(run?.isActive ?? false);
    void send(NodeCommandType c) => ref.read(nodeCommandsProvider.notifier).send(node.nodeId, c);
    const gap = SizedBox(height: 8);
    final outlined = OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48));
    final silence = OutlinedButton.icon(
      style: outlined,
      icon: const Icon(Icons.notifications_off_outlined),
      label: Text(l10n.silenceAlarmButton),
      onPressed: enabled ? () => send(NodeCommandType.silence) : null,
    );

    if (!node.online) children.addAll([gap, _Note(icon: Icons.cloud_off, text: l10n.testOfflineNote)]);
    children.add(const SizedBox(height: 10));
    if (node.kind == 'air') {
      children.addAll([
        FilledButton.icon(
          icon: const Icon(Icons.notifications_active),
          label: Text(l10n.testAlarmButton),
          onPressed: enabled ? () => send(NodeCommandType.test) : null,
        ),
        const SizedBox(height: 4),
        Text(l10n.testAlarmHint, style: TextStyle(fontSize: 13, color: context.palette.muted)),
        gap,
        silence,
      ]);
    } else {
      final open = valveOpen(node);
      if (open != false) {
        children.addAll([
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: HazardColors.info),
            icon: const Icon(Icons.plumbing),
            label: Text(l10n.closeValveButton),
            onPressed: enabled
                ? () async {
                    if (await confirmCloseValve(context)) send(NodeCommandType.close);
                  }
                : null,
          ),
          gap,
        ]);
      }
      if (open != true) {
        children.addAll([
          FilledButton.tonalIcon(
            icon: const Icon(Icons.water_drop_outlined),
            label: Text(l10n.openValveButton),
            onPressed: enabled ? () => send(NodeCommandType.open) : null,
          ),
          gap,
        ]);
      }
      children.add(silence);
    }
    if (run != null) children.addAll([const SizedBox(height: 10), CommandRunRow(run: run)]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// "Închizi robinetul?" — true when confirmed.
Future<bool> confirmCloseValve(BuildContext context) async {
  final l10n = context.l10n;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      icon: const Icon(Icons.plumbing),
      title: Text(l10n.closeValveConfirmTitle),
      content: Text(l10n.closeValveConfirmBody),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(88, 48)),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(l10n.closeValveButton),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Live result of the last press: "Trimis…" → "Reușit" / "Respins: …" /
/// "Fără răspuns". Announced by screen readers as it changes.
class CommandRunRow extends StatelessWidget {
  const CommandRunRow({super.key, required this.run});
  final CommandRun run;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final detail = l10n.commandDetail(run.detail);
    final (Widget lead, String title, String? sub, Color color) = switch (run.phase) {
      RunPhase.sending || RunPhase.sent => (
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          l10n.runSent,
          null,
          HazardColors.info,
        ),
      RunPhase.accepted => (
          const Icon(Icons.check_circle, color: HazardColors.normal, size: 24),
          l10n.runAccepted,
          detail,
          HazardColors.normal,
        ),
      RunPhase.rejected => (
          const Icon(Icons.warning_amber_rounded, color: _amberText, size: 24),
          detail == null ? l10n.runRejectedPlain : l10n.runRejected(detail),
          null,
          _amberText,
        ),
      RunPhase.timeout => (
          const Icon(Icons.help_outline, color: HazardColors.unknown, size: 24),
          l10n.runTimeout,
          l10n.runTimeoutHint,
          HazardColors.unknown,
        ),
      RunPhase.failed => (
          const Icon(Icons.error_outline, color: HazardColors.alarm, size: 24),
          l10n.runFailed(l10n.commandFailure(run.httpStatus, run.detail)),
          null,
          HazardColors.alarm,
        ),
    };
    final what = [l10n.commandName(run.command), if (sub != null) sub].join(' · ');
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.palette.tint(color),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.palette.stateBorder(color)),
        ),
        child: Row(
          children: [
            lead,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: context.palette.ink(color))),
                  Text(what, style: TextStyle(fontSize: 13, color: context.palette.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: context.palette.muted),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(fontSize: 14, color: context.palette.muted))),
      ],
    );
  }
}

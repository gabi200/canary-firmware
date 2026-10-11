// Device commands: detail words, the run state machine (sent → accepted /
// rejected / timeout), who may command what, the test-all runner's spacing and
// the live controller (WebSocket result, early result, poll fallback, timeout).
import 'dart:async';

import 'package:canary_resident/src/i18n.dart';
import 'package:canary_resident/src/logic/node_commands.dart';
import 'package:canary_resident/src/models/node_command.dart';
import 'package:canary_resident/src/models/summary.dart';
import 'package:canary_resident/src/models/zone_info.dart';
import 'package:canary_resident/src/state/command_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_hub.dart';

/// Waits (real time, ≤ 10 s) until [done] holds.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 2000 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final ro = lookupAppLocalizations(const Locale('ro'));
final en = lookupAppLocalizations(const Locale('en'));

Map<String, Object?> _accepted(String id, {String detail = 'self_test', String status = 'accepted'}) => {
      'command_id': id, 'command': 'TEST', 'status': status, 'detail': detail,
      'requested_by_name': 'Ana Popescu', 'sent_ts': '2026-10-10T12:00:00Z', 'result_ts': '2026-10-10T12:00:01Z',
    };

void main() {
  group('detail words', () {
    test('firmware codes in Romanian', () {
      expect(ro.commandDetail('self_test'), 'autotest pornit');
      expect(ro.commandDetail('silenced'), 'alarmă oprită');
      expect(ro.commandDetail('self_test_busy'), 'un autotest rulează deja');
      expect(ro.commandDetail('alarm_inactive'), 'nicio alarmă activă');
      expect(ro.commandDetail('open'), 'robinet deschis');
      expect(ro.commandDetail('closed'), 'robinet închis');
      expect(ro.commandDetail('busy'), 'senzorul e ocupat cu altă comandă');
      expect(ro.commandDetail('invalid_command'), 'senzorul nu cunoaște comanda');
      // Water rejectionDetail() and the valve save failure.
      expect(ro.commandDetail('sensor_wet'), 'senzorul detectează încă apă');
      expect(ro.commandDetail('sensor_uninitialized'), 'senzorul încă pornește');
      expect(ro.commandDetail('ota_active'), 'senzorul se actualizează');
      expect(ro.commandDetail('command_rejected'), 'senzorul a refuzat comanda');
      expect(ro.commandDetail('persistence_failed'), 'starea robinetului nu s-a putut salva');
    });

    test('English, unknown codes as sent, nothing for null', () {
      expect(en.commandDetail('self_test'), 'self-test started');
      expect(en.commandDetail('closed'), 'valve closed');
      expect(ro.commandDetail('new_thing'), 'new thing');
      expect(ro.commandDetail(null), isNull);
      expect(ro.commandDetail(''), isNull);
    });

    test('why the hub would not send', () {
      expect(ro.commandFailure(409, null), 'senzorul e deconectat');
      expect(ro.commandFailure(429, null), 'așteaptă câteva secunde între comenzi');
      expect(ro.commandFailure(404, 'Not Found'), 'senzorul nu e în apartamentul tău');
      expect(ro.commandFailure(503, null), 'hub-ul nu e conectat la senzori acum');
      expect(ro.commandFailure(null, null), ro.serverUnreachable);
      expect(ro.commandFailure(500, 'boom'), 'boom');
    });

    test('"Ultimul test" line', () {
      final now = DateTime.utc(2026, 10, 10, 12, 2, 31);
      final c = NodeCommand.tryParse(_accepted('c1'));
      expect(ro.lastTestText(c, now: now), 'Ultimul test: reușit · acum 2 min');
      expect(ro.lastTestText(null), 'Netestat');
      expect(en.lastTestText(c, now: now), 'Last test: passed · 2 min ago');
      expect(ro.lastTestText(c, now: now, short: true), 'Test: reușit · acum 2 min');
      final rejected = NodeCommand.tryParse(_accepted('c2', status: 'rejected', detail: 'alarm_inactive'));
      expect(ro.lastTestText(rejected, now: now), 'Ultimul test: respins · acum 2 min');
      // Not a test: named, so a refused silence doesn't read as a failed test.
      final silence = NodeCommand.tryParse(
          {..._accepted('c3', status: 'rejected', detail: 'alarm_inactive'), 'command': 'SILENCE'});
      expect(ro.lastTestText(silence, now: now), 'Oprire alarmă: respins · acum 2 min');
      final close = NodeCommand.tryParse({..._accepted('c4', detail: 'closed'), 'command': 'CLOSE', 'result_ts': null});
      expect(ro.lastTestText(close, now: now), 'Închidere robinet: reușit · acum 2 min');
    });
  });

  group('parsing', () {
    test('command item and summary last_command', () {
      final c = NodeCommand.tryParse(_accepted('c1'))!;
      expect(c.type, NodeCommandType.test);
      expect(c.status, CommandStatus.accepted);
      expect(c.ts, DateTime.utc(2026, 10, 10, 12, 0, 1));
      expect(NodeCommand.tryParse({'command_id': 'x', 'status': 'weird'}), isNull);
      expect(NodeCommand.tryParse(null), isNull);
      final node = NodeAnalysis.fromJson({'node_id': 'air-1', 'kind': 'air', 'last_command': _accepted('c1')});
      expect(node.lastCommand?.commandId, 'c1');
      expect(NodeAnalysis.fromJson({'node_id': 'air-1', 'last_command': null}).lastCommand, isNull);
    });

    test('commands per kind; never a valve command for air', () {
      expect(NodeCommandType.forKind('air'), [NodeCommandType.test, NodeCommandType.silence]);
      expect(NodeCommandType.forKind('water'), containsAll([NodeCommandType.open, NodeCommandType.close]));
      expect(NodeCommandType.forKind('other'), isEmpty);
    });
  });

  group('run state machine', () {
    final t0 = DateTime.utc(2026, 10, 10, 12);
    CommandRun start() => CommandRun.start('air-1', NodeCommandType.test, t0);

    test('sending → sent → accepted', () {
      final sent = start().sent('c1');
      expect(sent.phase, RunPhase.sent);
      expect(sent.isActive, isTrue);
      final done = sent.result('c1', CommandStatus.accepted, detail: 'self_test');
      expect(done.phase, RunPhase.accepted);
      expect(done.detail, 'self_test');
      expect(done.isFinal, isTrue);
    });

    test('sent → rejected / hub timeout / local timeout', () {
      final sent = start().sent('c1');
      expect(sent.result('c1', CommandStatus.rejected, detail: 'self_test_busy').phase, RunPhase.rejected);
      expect(sent.result('c1', CommandStatus.timeout).phase, RunPhase.timeout);
      expect(sent.timedOut().phase, RunPhase.timeout);
      expect(start().timedOut().phase, RunPhase.timeout); // the request itself hung
    });

    test('ignores other commands, "sent" updates and anything after the end', () {
      final sent = start().sent('c1');
      expect(sent.result('other', CommandStatus.accepted), same(sent));
      expect(sent.result('c1', CommandStatus.sent), same(sent));
      expect(start().result('c1', CommandStatus.accepted).phase, RunPhase.sending); // id not known yet
      final done = sent.result('c1', CommandStatus.rejected);
      expect(done.result('c1', CommandStatus.accepted), same(done));
      expect(done.timedOut(), same(done));
      expect(sent.timedOut().result('c1', CommandStatus.accepted).phase, RunPhase.timeout);
    });

    test('hub refused to send', () {
      final failed = start().failed(409, 'Node offline');
      expect(failed.phase, RunPhase.failed);
      expect(failed.httpStatus, 409);
      expect(failed.sent('c1'), same(failed));
      expect(start().sent('c1').failed(429, null).phase, RunPhase.sent);
    });
  });

  group('who may command', () {
    const own = ZoneInfo(id: 'zone_kitchen', label: 'Bucătărie', unitId: 'unit_0312');
    const common = ZoneInfo(id: 'zone_hallway', label: 'Hol', unitId: 'common');
    const other = ZoneInfo(id: 'zone_x', label: 'X', unitId: 'unit_0999');

    test('residents: own units only; common areas get the note', () {
      expect(commandAccess(role: 'resident', zone: own, ownUnitIds: {'unit_0312'}), CommandAccess.allowed);
      expect(commandAccess(role: 'resident', zone: own), CommandAccess.allowed); // /me not loaded yet
      expect(commandAccess(role: 'resident', zone: common, ownUnitIds: {'unit_0312'}), CommandAccess.commonArea);
      expect(commandAccess(role: 'resident', zone: other, ownUnitIds: {'unit_0312'}), CommandAccess.none);
      expect(commandAccess(role: 'resident', zone: null), CommandAccess.none);
    });

    test('managers and admins everything, dispatchers nothing', () {
      expect(commandAccess(role: 'hoa_manager', zone: common), CommandAccess.allowed);
      expect(commandAccess(role: 'system_admin', zone: null), CommandAccess.allowed);
      expect(commandAccess(role: 'dispatcher_external', zone: own), CommandAccess.none);
      expect(commandAccess(role: null, zone: own), CommandAccess.none);
    });

    test('valve position and the newest command of a room', () {
      NodeAnalysis water(String level) => NodeAnalysis.fromJson({
            'node_id': 'w', 'kind': 'water',
            'indicators': [{'key': 'valve', 'level': level, 'value': '-'}],
          });
      expect(valveOpen(water('ok')), isTrue);
      expect(valveOpen(water('attention')), isFalse);
      expect(valveOpen(water('unknown')), isNull);
      final older = NodeAnalysis.fromJson({'node_id': 'a', 'last_command': _accepted('old')});
      final newer = NodeAnalysis.fromJson({
        'node_id': 'b',
        'last_command': {..._accepted('new'), 'result_ts': '2026-10-10T12:05:00Z'},
      });
      expect(latestCommand([older, newer, NodeAnalysis.fromJson({'node_id': 'c'})])?.commandId, 'new');
      expect(latestCommand([NodeAnalysis.fromJson({'node_id': 'c'})]), isNull);
    });
  });

  group('test-all runner', () {
    test('one at a time, at least 3 s apart, in order', () async {
      var now = DateTime.utc(2026, 10, 10, 12);
      final starts = <String, DateTime>{};
      var inFlight = 0;
      var maxInFlight = 0;
      final runner = SequentialTestRunner(
        clock: () => now,
        wait: (d) async => now = now.add(d),
        send: (id) async {
          starts[id] = now;
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          // The device answers after 1 s (the last one after 20 s: hub timeout).
          now = now.add(Duration(seconds: id == 'c' ? 20 : 1));
          inFlight--;
          return CommandRun.start(id, NodeCommandType.test, starts[id]!).sent('x').result('x', CommandStatus.accepted);
        },
      );
      final results = await runner.run(['a', 'b', 'c', 'd']);
      expect(results.keys, ['a', 'b', 'c', 'd']);
      expect(maxInFlight, 1);
      final times = starts.values.toList();
      for (var i = 1; i < times.length; i++) {
        expect(times[i].difference(times[i - 1]), greaterThanOrEqualTo(const Duration(seconds: 3)));
      }
      expect(times[1].difference(times[0]), runner.spacing);
      // A slow answer already spaces them: no extra wait after 'c'.
      expect(times[3].difference(times[2]), const Duration(seconds: 20));
    });

    test('cancel stops before the next sensor', () async {
      final sent = <String>[];
      late SequentialTestRunner runner;
      runner = SequentialTestRunner(
        wait: (_) async {},
        send: (id) async {
          sent.add(id);
          runner.cancel();
          return CommandRun.start(id, NodeCommandType.test, DateTime.now()).timedOut();
        },
      );
      await runner.run(['a', 'b']);
      expect(sent, ['a']);
    });
  });

  group('live controller', () {
    late FakeHub hub;
    late StreamController<Map<String, dynamic>> ws;
    late int settled;

    NodeCommandController controller({Duration timeout = const Duration(seconds: 5)}) {
      final c = NodeCommandController(fakeApi(hub), ws.stream,
          onSettled: () => settled++, timeout: timeout, pollEvery: const Duration(milliseconds: 40));
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      hub = FakeHub();
      ws = StreamController<Map<String, dynamic>>.broadcast();
      settled = 0;
      hub.reply('POST /api/v1/nodes/air-1/commands', 202,
          {'command_id': 'c1', 'node_id': 'air-1', 'command': 'TEST', 'status': 'sent', 'sent_ts': '2026-10-10T12:00:00Z'});
      hub.reply('GET /api/v1/nodes/air-1/commands', 200, [
        {..._accepted('c1'), 'status': 'sent', 'detail': null},
      ]);
    });

    test('WebSocket result settles the run', () async {
      final c = controller();
      final done = c.send('air-1', NodeCommandType.test);
      await _until(() => c.state['air-1']?.phase == RunPhase.sent);
      expect(c.state['air-1']?.phase, RunPhase.sent);
      expect(hub.calls('POST', '/api/v1/nodes/air-1/commands').single.data, {'command': 'TEST'});
      ws.add({'type': 'command_result', 'node_id': 'air-1', 'command_id': 'other', 'status': 'accepted'});
      await Future<void>.delayed(Duration.zero);
      expect(c.state['air-1']?.phase, RunPhase.sent);
      ws.add({
        'type': 'command_result', 'building_id': 'bld', 'node_id': 'air-1', 'command_id': 'c1', 'command': 'TEST',
        'status': 'rejected', 'detail': 'self_test_busy', 'ts': '2026-10-10T12:00:01Z',
      });
      final run = await done;
      expect(run.phase, RunPhase.rejected);
      expect(run.detail, 'self_test_busy');
      expect(settled, 1);
    });

    test('a result that beats the 202 is kept', () async {
      hub.on('POST /api/v1/nodes/air-1/commands', (_) {
        ws.add({'type': 'command_result', 'node_id': 'air-1', 'command_id': 'c1', 'status': 'accepted', 'detail': 'self_test'});
        return (202, {'command_id': 'c1', 'node_id': 'air-1', 'command': 'TEST', 'status': 'sent'});
      });
      final run = await controller().send('air-1', NodeCommandType.test);
      expect(run.phase, RunPhase.accepted);
    });

    test('poll fallback when no WebSocket frame comes', () async {
      final c = controller();
      final done = c.send('air-1', NodeCommandType.test);
      await _until(() => hub.calls('GET', '/api/v1/nodes/air-1/commands').isNotEmpty);
      expect(c.state['air-1']?.phase, RunPhase.sent); // the poll still says "sent"
      hub.reply('GET /api/v1/nodes/air-1/commands', 200, [_accepted('c1')]);
      final run = await done;
      expect(run.phase, RunPhase.accepted);
      expect(hub.calls('GET', '/api/v1/nodes/air-1/commands').first.queryParameters['limit'], 5);
    });

    test('no answer → timeout; hub refusal → failed; one at a time per sensor', () async {
      final c = controller(timeout: const Duration(milliseconds: 150));
      final first = c.send('air-1', NodeCommandType.test);
      final again = c.send('air-1', NodeCommandType.silence);
      expect((await first).phase, RunPhase.timeout);
      expect((await again).command, NodeCommandType.test);
      expect(hub.calls('POST', '/api/v1/nodes/air-1/commands'), hasLength(1));

      hub.reply('POST /api/v1/nodes/air-1/commands', 409, {'detail': 'Node offline'});
      final failed = await controller().send('air-1', NodeCommandType.test); // roomy timeout
      expect(failed.phase, RunPhase.failed);
      expect(failed.httpStatus, 409);
      expect(ro.commandFailure(failed.httpStatus, failed.detail), 'senzorul e deconectat');
      expect(settled, 2);
    });
  });
}

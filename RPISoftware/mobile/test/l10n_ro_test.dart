import 'dart:io';

import 'package:canary_resident/l10n/gen/app_localizations.dart';
import 'package:canary_resident/src/logic/connection_status.dart';
import 'package:canary_resident/src/models/check_in.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ro = lookupAppLocalizations(const Locale('ro'));

  test('Romanian emergency and plural strings use the Romanian catalog', () {
    expect(ro.evacuateNow, 'EVACUAȚI ACUM');
    expect(ro.checkInsQueued(2), '2 confirmări în așteptare');
    expect(CheckInStatus.safeOutside.label(ro), 'Sunt afară, în siguranță');
    expect(
      liveConnectionLabel(ro, lastMessageAt: DateTime.utc(2026), now: DateTime.utc(2026).add(const Duration(seconds: 8))),
      'Conectat · actualizat acum 8 s',
    );
  });

  test('Romanian ARB has no cedilla Romanian letters', () {
    final arb = File('lib/l10n/app_ro.arb').readAsStringSync();
    expect(arb.contains(RegExp('[şţŞŢ]')), isFalse);
  });
}

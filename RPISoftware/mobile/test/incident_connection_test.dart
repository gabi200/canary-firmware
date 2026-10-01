import 'package:canary_resident/src/logic/connection_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:canary_resident/l10n/gen/app_localizations.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  test('does not forward hello and ping control frames to incident consumers', () {
    expect(isConnectionControlFrame(const {'type': 'hello'}), isTrue);
    expect(isConnectionControlFrame(const {'type': 'ping'}), isTrue);
    expect(isConnectionControlFrame(const {'type': 'incident'}), isFalse);
  });

  test('shows just now for a current live frame', () {
    final now = DateTime.utc(2026, 10, 1, 12);
    expect(
      liveConnectionLabel(en, lastMessageAt: now.subtract(const Duration(seconds: 4)), now: now),
      'Live · updated just now',
    );
  });

  test('shows elapsed seconds for an older live frame', () {
    final now = DateTime.utc(2026, 10, 1, 12);
    expect(
      liveConnectionLabel(en, lastMessageAt: now.subtract(const Duration(seconds: 17)), now: now),
      'Live · updated 17 s ago',
    );
  });

  test('marks a 40-second-old link stale', () {
    final now = DateTime.utc(2026, 10, 1, 12);
    expect(
      isConnectionFresh(now.subtract(const Duration(seconds: 40)), now),
      isFalse,
    );
  });
}

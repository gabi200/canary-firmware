// This is a basic Flutter widget test for CanaryApp.

import 'support/fake_hub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:canary_resident/main.dart';
import 'package:canary_resident/src/services/storage.dart';
import 'package:canary_resident/src/state/providers.dart';

void main() {
  testWidgets('CanaryApp widget smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final sharedPrefs = await SharedPreferences.getInstance();
    final storage = Storage(sharedPrefs);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageProvider.overrideWithValue(storage),
          hubFound(storage),
        ],
        child: const CanaryApp(),
      ),
    );

    await tester.pump(); // the (fake) hub search completes

    // Expect to find "Canary" text on the onboarding screen
    expect(find.text('Canary'), findsWidgets);
  });
}


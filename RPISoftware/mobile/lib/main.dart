import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/services/notifications.dart';
import 'src/services/storage.dart';
import 'src/state/providers.dart';
import 'src/theme.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/manager_dashboard_screen.dart';
import 'src/ui/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await Storage.create();
  await Notifications.instance.init();

  runApp(
    ProviderScope(
      overrides: [storageProvider.overrideWithValue(storage)],
      child: const CanaryApp(),
    ),
  );
}

class CanaryApp extends ConsumerWidget {
  const CanaryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final Widget home;
    if (session == null) {
      home = const OnboardingScreen();
    } else if (session.isResident) {
      home = const HomeScreen();
    } else {
      // Managers, dispatchers and admins get the operations dashboard.
      home = const ManagerDashboardScreen();
    }
    return MaterialApp(
      title: 'Canary',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: home,
    );
  }
}

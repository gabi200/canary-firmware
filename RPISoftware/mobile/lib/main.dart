import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/config.dart';
import 'src/i18n.dart';
import 'src/services/notifications.dart';
import 'src/services/storage.dart';
import 'src/state/account_providers.dart';
import 'src/state/locale_controller.dart';
import 'src/state/mode_controller.dart';
import 'src/state/providers.dart';
import 'src/theme.dart';
import 'src/models/household.dart';
import 'src/ui/care_profiles_screen.dart';
import 'src/ui/invite_accept_screen.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/manager_dashboard_screen.dart';
import 'src/ui/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await Storage.create();

  runApp(
    ProviderScope(
      overrides: [storageProvider.overrideWithValue(storage)],
      child: const CanaryApp(),
    ),
  );
  // After runApp: on iOS this waits for the notification permission prompt,
  // which must not keep the app blank behind it.
  await Notifications.instance.init(lookupAppLocalizations(Locale(initialLanguageCode(storage))));
}

final _navigatorKey = GlobalKey<NavigatorState>();
var _startRouteOpened = false;

/// Opens [Config.startRoute] once, for QA / screenshots (off by default).
void _openStartRoute() {
  final navigator = _navigatorKey.currentState;
  if (navigator == null) return;
  switch (Config.startRoute) {
    case 'care':
      navigator.push(MaterialPageRoute<void>(builder: (_) => const CareProfilesScreen()));
    case 'care-health':
      navigator.push(MaterialPageRoute<void>(
          builder: (_) => const CareProfileFormScreen(initialSelf: true, autoImportHealth: true)));
  }
}

class CanaryApp extends ConsumerWidget {
  const CanaryApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final locale = ref.watch(localeProvider);
    ref.watch(languageSyncProvider); // keep the hub's notification language in step
    // Follow the hub's demo / real mode (5 s poll while signed in); listen, so
    // an answer never rebuilds the app root.
    ref.listen(hubModeProvider, (_, __) {});
    ref.listen<AppLocalizations>(
      l10nProvider,
      (_, l10n) => Notifications.instance.setLocalizations(l10n),
    );
    final Widget home;
    if (session == null) {
      home = const OnboardingScreen();
    } else if (session.isResident) {
      home = const HomeScreen();
    } else {
      // Managers, dispatchers and admins get the operations dashboard.
      home = const ManagerDashboardScreen();
    }
    if (Config.startRoute.isNotEmpty && !_startRouteOpened && (session?.isResident ?? false)) {
      _startRouteOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openStartRoute());
    }
    return MaterialApp(
      navigatorKey: _navigatorKey,
      onGenerateTitle: (context) => context.l10n.appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(brightness: Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      // App-chosen language (RO / EN); Material/Cupertino widgets follow it too.
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
      // Deep links: /join/<code> (https / web) and /<code> (canary://join/<code>)
      // open the household invite, signing in first if needed.
      onGenerateRoute: (settings) {
        final code = inviteCodeFromRoute(settings.name);
        if (code == null) return null;
        return MaterialPageRoute<void>(settings: settings, builder: (_) => InviteGate(code: code));
      },
    );
  }
}

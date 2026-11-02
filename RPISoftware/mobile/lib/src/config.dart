/// App-wide configuration.
///
/// The hub's address is found at run time (services/hub_locator.dart). For development,
/// an address can be given at build time; it is tried first, and discovery still runs
/// when it stops answering, e.g. from an Android emulator (10.0.2.2 == host loopback):
///   flutter run --dart-define=CANARY_API=http://10.0.2.2:8000
class Config {
  /// REST base tried before discovery, e.g. http://10.0.2.2:8000. Empty: discover only.
  static const String apiOverride = String.fromEnvironment('CANARY_API');

  /// WebSocket base for a REST base: http://x:8000 -> ws://x:8000.
  static String wsBaseFor(String apiBase) => apiBase.replaceFirst(RegExp(r'^http'), 'ws');

  /// Default building for the MVP (matches the seeded bld_007).
  static const String defaultBuildingId = String.fromEnvironment(
    'CANARY_BUILDING',
    defaultValue: 'bld_007',
  );

  /// Remote push via FCM. Off by default so the app runs without Firebase config.
  /// Turn on once google-services.json / GoogleService-Info.plist are in place.
  static const bool enableFirebasePush = bool.fromEnvironment(
    'CANARY_FCM',
    defaultValue: false,
  );

  /// QA / screenshot aid: a screen to open right after start (residents), e.g.
  /// `--dart-define=CANARY_START_ROUTE=care-health` opens the care form for
  /// "Pentru mine" and starts the Apple Health import. Empty (off) by default.
  static const String startRoute = String.fromEnvironment('CANARY_START_ROUTE');

  /// States that put the app into the full-screen emergency experience.
  static const Set<String> alarmingStates = {'alarm', 'escalation', 'evacuation'};
}

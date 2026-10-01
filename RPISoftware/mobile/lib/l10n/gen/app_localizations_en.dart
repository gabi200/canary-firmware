// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Canary';

  @override
  String get evacuateNow => 'EVACUATE NOW';

  @override
  String get minimize => 'Minimize';

  @override
  String get call112 => 'Call 112';

  @override
  String get dial112 => 'Dial 112 on your phone';

  @override
  String get allClear => 'All clear';

  @override
  String get hazardCleared => 'The hazard has cleared.';

  @override
  String get returnLabel => 'Return';

  @override
  String get gasLeak => 'Gas leak';

  @override
  String get carbonMonoxide => 'Carbon monoxide';

  @override
  String get waterLeak => 'Water leak';

  @override
  String get smokeParticulates => 'Smoke / particulates';

  @override
  String get hazardGasDont =>
      'Don\'t use the lift, light switches, or open flames.';

  @override
  String get hazardCoDont => 'Don\'t stay inside. Get to fresh air now.';

  @override
  String get hazardSmokeDont => 'Stay low under smoke. Don\'t use the lift.';

  @override
  String get hazardWaterDont =>
      'Don\'t touch electrical devices or switches near water.';

  @override
  String get hazardDefaultDont => 'Don\'t use the lift.';

  @override
  String get stateDetection => 'Detected';

  @override
  String get stateVerification => 'Verifying';

  @override
  String get stateAlarm => 'Alarm';

  @override
  String get stateEvacuation => 'Evacuate now';

  @override
  String get stateEscalation => 'Emergency response';

  @override
  String get stateResolution => 'Resolved';

  @override
  String get stateFalseAlarm => 'False alarm';

  @override
  String get stateNormal => 'All clear';

  @override
  String get safeOutside => 'I\'m safe / evacuated';

  @override
  String get safeInside => 'Safe but still inside';

  @override
  String get needsHelp => 'I need help';

  @override
  String get liveJustNow => 'Live · updated just now';

  @override
  String liveUpdated(int seconds) {
    return 'Live · updated $seconds s ago';
  }

  @override
  String get offlineSavedRoute => 'Offline · showing saved route';

  @override
  String get offlineNoRoute => 'Offline · no route available';

  @override
  String get routeCrossesHazard =>
      'This route passes near the hazard. Use another marked exit if you can, and call 112.';

  @override
  String get routeSafetyUnknown =>
      'We couldn\'t check this route against the hazard. Follow the marked exits, stay away from the hazard, and call 112 if unsure.';

  @override
  String get evacuationRoute => 'Evacuation route';

  @override
  String get fallbackLeave =>
      'Leave by the nearest safe exit. Do not use the lift.';

  @override
  String get fallbackAssembly =>
      'Go to the outdoor assembly point and do not return inside.';

  @override
  String checkInSent(Object status) {
    return 'Check-in sent: $status';
  }

  @override
  String get checkInQueued =>
      'Offline — check-in queued, will send automatically';

  @override
  String checkedIn(Object status) {
    return 'Checked in: $status';
  }

  @override
  String get change => 'Change';

  @override
  String get outAndSafe => 'I\'m out and safe';

  @override
  String get safeStillInside => 'I\'m safe but still inside';

  @override
  String savedRoute(Object time) {
    return 'Saved route from $time — it may not reflect current blockages';
  }

  @override
  String get startHere => 'Start here';

  @override
  String avoid(Object name) {
    return 'Avoid: $name';
  }

  @override
  String routeStep(int step, int total, Object label, Object hint) {
    return 'Step $step of $total: $label.$hint';
  }

  @override
  String get live => 'Live';

  @override
  String get reconnecting => 'Reconnecting…';

  @override
  String checkInsQueued(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count check-ins queued',
      one: '1 check-in queued',
      zero: 'No check-ins queued',
    );
    return '$_temp0';
  }

  @override
  String get openEvacuationGuidance => 'Open evacuation guidance';

  @override
  String get activeIncidents => 'Active incidents';

  @override
  String get noActiveIncidents => 'No active incidents';

  @override
  String get buildingMonitored => 'Your building is being monitored.';

  @override
  String get noActiveHazard =>
      'No active hazard. You will be alerted immediately if anything is detected.';

  @override
  String get settings => 'Settings';

  @override
  String get account => 'Account';

  @override
  String get presenceContribution => 'Presence contribution';

  @override
  String get sharePresence => 'Share my presence during incidents';

  @override
  String get sharePresenceDescription =>
      'Lets responders better account for who is inside. Anonymous; used only during an active incident.';

  @override
  String get about => 'About';

  @override
  String get canaryResident => 'Canary resident';

  @override
  String get appVersion =>
      'v0.1.0 — advisory safety app. Not a substitute for certified alarms.';

  @override
  String get server => 'Server';

  @override
  String get signOut => 'Sign out';

  @override
  String get residentSafety => 'Building safety for residents';

  @override
  String get username => 'Username';

  @override
  String get buildingId => 'Building ID';

  @override
  String get linkUnit => 'Link my unit';

  @override
  String serverValue(Object server) {
    return 'Server: $server';
  }

  @override
  String get orderEvacuation => 'Order evacuation';

  @override
  String get resolve => 'Resolve';

  @override
  String get dismiss => 'Dismiss';

  @override
  String doneAction(Object action) {
    return 'Done: $action';
  }

  @override
  String get victimAccounting => 'Victim accounting';

  @override
  String get couldNotLoadAccounting => 'Could not load accounting';

  @override
  String get occupants => 'Occupants';

  @override
  String get accounted => 'Accounted';

  @override
  String get unaccounted => 'Unaccounted';

  @override
  String get needHelp => 'Need help';

  @override
  String get residentAccountability => 'Resident accountability';

  @override
  String get couldNotLoadRoster => 'Could not load roster';

  @override
  String get noResidents => 'No residents registered.';

  @override
  String get needsHelpUpper => 'NEEDS HELP';

  @override
  String get safeOut => 'Safe — out';

  @override
  String get safeIn => 'Safe — in';

  @override
  String get noResponse => 'No response';

  @override
  String get awaiting => 'Awaiting';

  @override
  String get buildingSensors => 'Building sensors';

  @override
  String get homeStatus => 'Home status';

  @override
  String sensorsOnline(int online, int total) {
    return '$online of $total sensors online';
  }

  @override
  String activeIncidentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count active incidents',
      one: '1 active incident',
    );
    return '$_temp0';
  }

  @override
  String get occupied => 'occupied';

  @override
  String get empty => 'empty';

  @override
  String get noData => 'no data';

  @override
  String get noRecentData => 'No recent data';

  @override
  String get offline => 'Offline';

  @override
  String lastSeen(Object what, Object time) {
    return '$what · last seen $time';
  }

  @override
  String get whatToDo => 'What to do';

  @override
  String get loadingSensorStatus => 'Loading sensor status…';

  @override
  String get sensorStatusUnavailable => 'Sensor status unavailable';

  @override
  String get cannotReachHub =>
      'Can\'t reach the hub right now. Pull down to retry.';

  @override
  String get noSensors => 'No sensors connected';

  @override
  String get sensorStatusAppears =>
      'Sensor status appears here once a Canary device joins the hub.';

  @override
  String get couldNotRefresh => 'Couldn\'t refresh sensor status';

  @override
  String couldNotRefreshFrom(Object time) {
    return 'Couldn\'t refresh · showing status from $time';
  }

  @override
  String get needsAttention => 'Needs attention';

  @override
  String get danger => 'Danger';

  @override
  String get statusUnknown => 'Status unknown';

  @override
  String get airSensor => 'Air sensor';

  @override
  String get waterSensor => 'Water sensor';

  @override
  String get sensor => 'Sensor';

  @override
  String get airQuality => 'Air quality';

  @override
  String get gas => 'Gas';

  @override
  String get comfort => 'Comfort';

  @override
  String get occupancy => 'Occupancy';

  @override
  String get waterValve => 'Water valve';

  @override
  String get justNow => 'just now';

  @override
  String minutesAgo(int count) {
    return '$count min ago';
  }

  @override
  String hoursAgo(int count) {
    return '$count h ago';
  }

  @override
  String daysAgo(int count) {
    return '$count d ago';
  }

  @override
  String get notificationChannelName => 'Emergency alerts';

  @override
  String get notificationChannelDescription =>
      'Critical building safety alarms (gas, CO, evacuation).';

  @override
  String alertNotificationTitle(Object hazard) {
    return '$hazard alert';
  }

  @override
  String get openAppForGuidance => 'Open Canary for guidance.';

  @override
  String get loginFailed => 'Could not sign in. Please try again.';

  @override
  String get actionFailed => 'Could not complete the action. Please try again.';
}

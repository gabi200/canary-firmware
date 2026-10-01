import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ro.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ro')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Canary'**
  String get appTitle;

  /// No description provided for @evacuateNow.
  ///
  /// In en, this message translates to:
  /// **'EVACUATE NOW'**
  String get evacuateNow;

  /// No description provided for @minimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get minimize;

  /// No description provided for @call112.
  ///
  /// In en, this message translates to:
  /// **'Call 112'**
  String get call112;

  /// No description provided for @dial112.
  ///
  /// In en, this message translates to:
  /// **'Dial 112 on your phone'**
  String get dial112;

  /// No description provided for @allClear.
  ///
  /// In en, this message translates to:
  /// **'All clear'**
  String get allClear;

  /// No description provided for @hazardCleared.
  ///
  /// In en, this message translates to:
  /// **'The hazard has cleared.'**
  String get hazardCleared;

  /// No description provided for @returnLabel.
  ///
  /// In en, this message translates to:
  /// **'Return'**
  String get returnLabel;

  /// No description provided for @gasLeak.
  ///
  /// In en, this message translates to:
  /// **'Gas leak'**
  String get gasLeak;

  /// No description provided for @carbonMonoxide.
  ///
  /// In en, this message translates to:
  /// **'Carbon monoxide'**
  String get carbonMonoxide;

  /// No description provided for @waterLeak.
  ///
  /// In en, this message translates to:
  /// **'Water leak'**
  String get waterLeak;

  /// No description provided for @smokeParticulates.
  ///
  /// In en, this message translates to:
  /// **'Smoke / particulates'**
  String get smokeParticulates;

  /// No description provided for @hazardGasDont.
  ///
  /// In en, this message translates to:
  /// **'Don\'t use the lift, light switches, or open flames.'**
  String get hazardGasDont;

  /// No description provided for @hazardCoDont.
  ///
  /// In en, this message translates to:
  /// **'Don\'t stay inside. Get to fresh air now.'**
  String get hazardCoDont;

  /// No description provided for @hazardSmokeDont.
  ///
  /// In en, this message translates to:
  /// **'Stay low under smoke. Don\'t use the lift.'**
  String get hazardSmokeDont;

  /// No description provided for @hazardWaterDont.
  ///
  /// In en, this message translates to:
  /// **'Don\'t touch electrical devices or switches near water.'**
  String get hazardWaterDont;

  /// No description provided for @hazardDefaultDont.
  ///
  /// In en, this message translates to:
  /// **'Don\'t use the lift.'**
  String get hazardDefaultDont;

  /// No description provided for @stateDetection.
  ///
  /// In en, this message translates to:
  /// **'Detected'**
  String get stateDetection;

  /// No description provided for @stateVerification.
  ///
  /// In en, this message translates to:
  /// **'Verifying'**
  String get stateVerification;

  /// No description provided for @stateAlarm.
  ///
  /// In en, this message translates to:
  /// **'Alarm'**
  String get stateAlarm;

  /// No description provided for @stateEvacuation.
  ///
  /// In en, this message translates to:
  /// **'Evacuate now'**
  String get stateEvacuation;

  /// No description provided for @stateEscalation.
  ///
  /// In en, this message translates to:
  /// **'Emergency response'**
  String get stateEscalation;

  /// No description provided for @stateResolution.
  ///
  /// In en, this message translates to:
  /// **'Resolved'**
  String get stateResolution;

  /// No description provided for @stateFalseAlarm.
  ///
  /// In en, this message translates to:
  /// **'False alarm'**
  String get stateFalseAlarm;

  /// No description provided for @stateNormal.
  ///
  /// In en, this message translates to:
  /// **'All clear'**
  String get stateNormal;

  /// No description provided for @safeOutside.
  ///
  /// In en, this message translates to:
  /// **'I\'m safe / evacuated'**
  String get safeOutside;

  /// No description provided for @safeInside.
  ///
  /// In en, this message translates to:
  /// **'Safe but still inside'**
  String get safeInside;

  /// No description provided for @needsHelp.
  ///
  /// In en, this message translates to:
  /// **'I need help'**
  String get needsHelp;

  /// No description provided for @liveJustNow.
  ///
  /// In en, this message translates to:
  /// **'Live · updated just now'**
  String get liveJustNow;

  /// No description provided for @liveUpdated.
  ///
  /// In en, this message translates to:
  /// **'Live · updated {seconds} s ago'**
  String liveUpdated(int seconds);

  /// No description provided for @offlineSavedRoute.
  ///
  /// In en, this message translates to:
  /// **'Offline · showing saved route'**
  String get offlineSavedRoute;

  /// No description provided for @offlineNoRoute.
  ///
  /// In en, this message translates to:
  /// **'Offline · no route available'**
  String get offlineNoRoute;

  /// No description provided for @routeCrossesHazard.
  ///
  /// In en, this message translates to:
  /// **'This route passes near the hazard. Use another marked exit if you can, and call 112.'**
  String get routeCrossesHazard;

  /// No description provided for @routeSafetyUnknown.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t check this route against the hazard. Follow the marked exits, stay away from the hazard, and call 112 if unsure.'**
  String get routeSafetyUnknown;

  /// No description provided for @evacuationRoute.
  ///
  /// In en, this message translates to:
  /// **'Evacuation route'**
  String get evacuationRoute;

  /// No description provided for @readAloud.
  ///
  /// In en, this message translates to:
  /// **'Read aloud'**
  String get readAloud;

  /// No description provided for @stopReading.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stopReading;

  /// No description provided for @spokenAssembly.
  ///
  /// In en, this message translates to:
  /// **'Then go to the assembly point: {name}.'**
  String spokenAssembly(Object name);

  /// No description provided for @fallbackLeave.
  ///
  /// In en, this message translates to:
  /// **'Leave by the nearest safe exit. Do not use the lift.'**
  String get fallbackLeave;

  /// No description provided for @fallbackAssembly.
  ///
  /// In en, this message translates to:
  /// **'Go to the outdoor assembly point and do not return inside.'**
  String get fallbackAssembly;

  /// No description provided for @checkInSent.
  ///
  /// In en, this message translates to:
  /// **'Check-in sent: {status}'**
  String checkInSent(Object status);

  /// No description provided for @checkInQueued.
  ///
  /// In en, this message translates to:
  /// **'Offline — check-in queued, will send automatically'**
  String get checkInQueued;

  /// No description provided for @checkedIn.
  ///
  /// In en, this message translates to:
  /// **'Checked in: {status}'**
  String checkedIn(Object status);

  /// No description provided for @change.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get change;

  /// No description provided for @outAndSafe.
  ///
  /// In en, this message translates to:
  /// **'I\'m out and safe'**
  String get outAndSafe;

  /// No description provided for @safeStillInside.
  ///
  /// In en, this message translates to:
  /// **'I\'m safe but still inside'**
  String get safeStillInside;

  /// No description provided for @savedRoute.
  ///
  /// In en, this message translates to:
  /// **'Saved route from {time} — it may not reflect current blockages'**
  String savedRoute(Object time);

  /// No description provided for @startHere.
  ///
  /// In en, this message translates to:
  /// **'Start here'**
  String get startHere;

  /// No description provided for @avoid.
  ///
  /// In en, this message translates to:
  /// **'Avoid: {name}'**
  String avoid(Object name);

  /// No description provided for @routeStep.
  ///
  /// In en, this message translates to:
  /// **'Step {step} of {total}: {label}.{hint}'**
  String routeStep(int step, int total, Object label, Object hint);

  /// No description provided for @live.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get live;

  /// No description provided for @reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get reconnecting;

  /// No description provided for @checkInsQueued.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No check-ins queued} one{1 check-in queued} other{{count} check-ins queued}}'**
  String checkInsQueued(int count);

  /// No description provided for @openEvacuationGuidance.
  ///
  /// In en, this message translates to:
  /// **'Open evacuation guidance'**
  String get openEvacuationGuidance;

  /// No description provided for @activeIncidents.
  ///
  /// In en, this message translates to:
  /// **'Active incidents'**
  String get activeIncidents;

  /// No description provided for @noActiveIncidents.
  ///
  /// In en, this message translates to:
  /// **'No active incidents'**
  String get noActiveIncidents;

  /// No description provided for @buildingMonitored.
  ///
  /// In en, this message translates to:
  /// **'Your building is being monitored.'**
  String get buildingMonitored;

  /// No description provided for @noActiveHazard.
  ///
  /// In en, this message translates to:
  /// **'No active hazard. You will be alerted immediately if anything is detected.'**
  String get noActiveHazard;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// No description provided for @presenceContribution.
  ///
  /// In en, this message translates to:
  /// **'Presence contribution'**
  String get presenceContribution;

  /// No description provided for @sharePresence.
  ///
  /// In en, this message translates to:
  /// **'Share my presence during incidents'**
  String get sharePresence;

  /// No description provided for @sharePresenceDescription.
  ///
  /// In en, this message translates to:
  /// **'Lets responders better account for who is inside. Anonymous; used only during an active incident.'**
  String get sharePresenceDescription;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @canaryResident.
  ///
  /// In en, this message translates to:
  /// **'Canary resident'**
  String get canaryResident;

  /// No description provided for @appVersion.
  ///
  /// In en, this message translates to:
  /// **'v0.1.0 — advisory safety app. Not a substitute for certified alarms.'**
  String get appVersion;

  /// No description provided for @server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get server;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOut;

  /// No description provided for @residentSafety.
  ///
  /// In en, this message translates to:
  /// **'Building safety for residents'**
  String get residentSafety;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @buildingId.
  ///
  /// In en, this message translates to:
  /// **'Building ID'**
  String get buildingId;

  /// No description provided for @linkUnit.
  ///
  /// In en, this message translates to:
  /// **'Link my unit'**
  String get linkUnit;

  /// No description provided for @serverValue.
  ///
  /// In en, this message translates to:
  /// **'Server: {server}'**
  String serverValue(Object server);

  /// No description provided for @orderEvacuation.
  ///
  /// In en, this message translates to:
  /// **'Order evacuation'**
  String get orderEvacuation;

  /// No description provided for @resolve.
  ///
  /// In en, this message translates to:
  /// **'Resolve'**
  String get resolve;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @doneAction.
  ///
  /// In en, this message translates to:
  /// **'Done: {action}'**
  String doneAction(Object action);

  /// No description provided for @victimAccounting.
  ///
  /// In en, this message translates to:
  /// **'Victim accounting'**
  String get victimAccounting;

  /// No description provided for @couldNotLoadAccounting.
  ///
  /// In en, this message translates to:
  /// **'Could not load accounting'**
  String get couldNotLoadAccounting;

  /// No description provided for @occupants.
  ///
  /// In en, this message translates to:
  /// **'Occupants'**
  String get occupants;

  /// No description provided for @accounted.
  ///
  /// In en, this message translates to:
  /// **'Accounted'**
  String get accounted;

  /// No description provided for @unaccounted.
  ///
  /// In en, this message translates to:
  /// **'Unaccounted'**
  String get unaccounted;

  /// No description provided for @needHelp.
  ///
  /// In en, this message translates to:
  /// **'Need help'**
  String get needHelp;

  /// No description provided for @residentAccountability.
  ///
  /// In en, this message translates to:
  /// **'Resident accountability'**
  String get residentAccountability;

  /// No description provided for @couldNotLoadRoster.
  ///
  /// In en, this message translates to:
  /// **'Could not load roster'**
  String get couldNotLoadRoster;

  /// No description provided for @noResidents.
  ///
  /// In en, this message translates to:
  /// **'No residents registered.'**
  String get noResidents;

  /// No description provided for @needsHelpUpper.
  ///
  /// In en, this message translates to:
  /// **'NEEDS HELP'**
  String get needsHelpUpper;

  /// No description provided for @safeOut.
  ///
  /// In en, this message translates to:
  /// **'Safe — out'**
  String get safeOut;

  /// No description provided for @safeIn.
  ///
  /// In en, this message translates to:
  /// **'Safe — in'**
  String get safeIn;

  /// No description provided for @noResponse.
  ///
  /// In en, this message translates to:
  /// **'No response'**
  String get noResponse;

  /// No description provided for @awaiting.
  ///
  /// In en, this message translates to:
  /// **'Awaiting'**
  String get awaiting;

  /// No description provided for @buildingSensors.
  ///
  /// In en, this message translates to:
  /// **'Building sensors'**
  String get buildingSensors;

  /// No description provided for @homeStatus.
  ///
  /// In en, this message translates to:
  /// **'Home status'**
  String get homeStatus;

  /// No description provided for @sensorsOnline.
  ///
  /// In en, this message translates to:
  /// **'{online} of {total} sensors online'**
  String sensorsOnline(int online, int total);

  /// No description provided for @activeIncidentCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{1 active incident} other{{count} active incidents}}'**
  String activeIncidentCount(int count);

  /// No description provided for @occupied.
  ///
  /// In en, this message translates to:
  /// **'occupied'**
  String get occupied;

  /// No description provided for @empty.
  ///
  /// In en, this message translates to:
  /// **'empty'**
  String get empty;

  /// No description provided for @noData.
  ///
  /// In en, this message translates to:
  /// **'no data'**
  String get noData;

  /// No description provided for @noRecentData.
  ///
  /// In en, this message translates to:
  /// **'No recent data'**
  String get noRecentData;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @lastSeen.
  ///
  /// In en, this message translates to:
  /// **'{what} · last seen {time}'**
  String lastSeen(Object what, Object time);

  /// No description provided for @whatToDo.
  ///
  /// In en, this message translates to:
  /// **'What to do'**
  String get whatToDo;

  /// No description provided for @loadingSensorStatus.
  ///
  /// In en, this message translates to:
  /// **'Loading sensor status…'**
  String get loadingSensorStatus;

  /// No description provided for @sensorStatusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Sensor status unavailable'**
  String get sensorStatusUnavailable;

  /// No description provided for @cannotReachHub.
  ///
  /// In en, this message translates to:
  /// **'Can\'t reach the hub right now. Pull down to retry.'**
  String get cannotReachHub;

  /// No description provided for @noSensors.
  ///
  /// In en, this message translates to:
  /// **'No sensors connected'**
  String get noSensors;

  /// No description provided for @sensorStatusAppears.
  ///
  /// In en, this message translates to:
  /// **'Sensor status appears here once a Canary device joins the hub.'**
  String get sensorStatusAppears;

  /// No description provided for @couldNotRefresh.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t refresh sensor status'**
  String get couldNotRefresh;

  /// No description provided for @couldNotRefreshFrom.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t refresh · showing status from {time}'**
  String couldNotRefreshFrom(Object time);

  /// No description provided for @needsAttention.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get needsAttention;

  /// No description provided for @danger.
  ///
  /// In en, this message translates to:
  /// **'Danger'**
  String get danger;

  /// No description provided for @statusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Status unknown'**
  String get statusUnknown;

  /// No description provided for @airSensor.
  ///
  /// In en, this message translates to:
  /// **'Air sensor'**
  String get airSensor;

  /// No description provided for @waterSensor.
  ///
  /// In en, this message translates to:
  /// **'Water sensor'**
  String get waterSensor;

  /// No description provided for @sensor.
  ///
  /// In en, this message translates to:
  /// **'Sensor'**
  String get sensor;

  /// No description provided for @airQuality.
  ///
  /// In en, this message translates to:
  /// **'Air quality'**
  String get airQuality;

  /// No description provided for @gas.
  ///
  /// In en, this message translates to:
  /// **'Gas'**
  String get gas;

  /// No description provided for @comfort.
  ///
  /// In en, this message translates to:
  /// **'Comfort'**
  String get comfort;

  /// No description provided for @occupancy.
  ///
  /// In en, this message translates to:
  /// **'Occupancy'**
  String get occupancy;

  /// No description provided for @waterValve.
  ///
  /// In en, this message translates to:
  /// **'Water valve'**
  String get waterValve;

  /// No description provided for @justNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get justNow;

  /// No description provided for @minutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String minutesAgo(int count);

  /// No description provided for @hoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} h ago'**
  String hoursAgo(int count);

  /// No description provided for @daysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} d ago'**
  String daysAgo(int count);

  /// No description provided for @notificationChannelName.
  ///
  /// In en, this message translates to:
  /// **'Emergency alerts'**
  String get notificationChannelName;

  /// No description provided for @notificationChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Critical building safety alarms (gas, CO, evacuation).'**
  String get notificationChannelDescription;

  /// No description provided for @alertNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'{hazard} alert'**
  String alertNotificationTitle(Object hazard);

  /// No description provided for @openAppForGuidance.
  ///
  /// In en, this message translates to:
  /// **'Open Canary for guidance.'**
  String get openAppForGuidance;

  /// No description provided for @loginFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not sign in. Please try again.'**
  String get loginFailed;

  /// No description provided for @actionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not complete the action. Please try again.'**
  String get actionFailed;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ro'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ro':
      return AppLocalizationsRo();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}

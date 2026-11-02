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
/// import 'l10n/app_localizations.dart';
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

  /// Brand name; not translated.
  ///
  /// In en, this message translates to:
  /// **'Canary'**
  String get appTitle;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageHint.
  ///
  /// In en, this message translates to:
  /// **'Also used for the sensor analysis from the hub.'**
  String get languageHint;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// Connection indicator: the live WebSocket feed is up.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get live;

  /// No description provided for @reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get reconnecting;

  /// No description provided for @allClear.
  ///
  /// In en, this message translates to:
  /// **'All clear'**
  String get allClear;

  /// No description provided for @evacuateNow.
  ///
  /// In en, this message translates to:
  /// **'EVACUATE NOW'**
  String get evacuateNow;

  /// No description provided for @onboardingTagline.
  ///
  /// In en, this message translates to:
  /// **'Building safety for residents'**
  String get onboardingTagline;

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

  /// No description provided for @linkMyUnit.
  ///
  /// In en, this message translates to:
  /// **'Link my unit'**
  String get linkMyUnit;

  /// No description provided for @serverAddress.
  ///
  /// In en, this message translates to:
  /// **'Server: {url}'**
  String serverAddress(String url);

  /// No description provided for @hubSearching.
  ///
  /// In en, this message translates to:
  /// **'Looking for the hub…'**
  String get hubSearching;

  /// No description provided for @hubNotFound.
  ///
  /// In en, this message translates to:
  /// **'No hub found on this Wi-Fi. Check that the phone is on the building\'s Wi-Fi.'**
  String get hubNotFound;

  /// No description provided for @hubRetry.
  ///
  /// In en, this message translates to:
  /// **'Search again'**
  String get hubRetry;

  /// No description provided for @hubManualLabel.
  ///
  /// In en, this message translates to:
  /// **'Hub address (e.g. 10.0.0.5)'**
  String get hubManualLabel;

  /// No description provided for @hubManualConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get hubManualConnect;

  /// No description provided for @hubManualFailed.
  ///
  /// In en, this message translates to:
  /// **'No hub answers at that address.'**
  String get hubManualFailed;

  /// No description provided for @loginFailed.
  ///
  /// In en, this message translates to:
  /// **'Login failed: {reason}'**
  String loginFailed(String reason);

  /// No description provided for @serverUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Can\'t reach the server. Check your connection.'**
  String get serverUnreachable;

  /// No description provided for @serverError.
  ///
  /// In en, this message translates to:
  /// **'Server error ({code})'**
  String serverError(int code);

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

  /// No description provided for @yourBuildingMonitored.
  ///
  /// In en, this message translates to:
  /// **'Your building is being monitored.'**
  String get yourBuildingMonitored;

  /// No description provided for @buildingMonitored.
  ///
  /// In en, this message translates to:
  /// **'Building is being monitored.'**
  String get buildingMonitored;

  /// No description provided for @noActiveHazard.
  ///
  /// In en, this message translates to:
  /// **'No active hazard. You will be alerted immediately if anything is detected.'**
  String get noActiveHazard;

  /// No description provided for @noActiveHazardInBuilding.
  ///
  /// In en, this message translates to:
  /// **'No active hazard in this building.'**
  String get noActiveHazardInBuilding;

  /// No description provided for @checkInsQueued.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 check-in queued} other{{count} check-ins queued}}'**
  String checkInsQueued(int count);

  /// No description provided for @hazardGasLeak.
  ///
  /// In en, this message translates to:
  /// **'Gas leak'**
  String get hazardGasLeak;

  /// No description provided for @hazardCarbonMonoxide.
  ///
  /// In en, this message translates to:
  /// **'Carbon monoxide'**
  String get hazardCarbonMonoxide;

  /// No description provided for @hazardWaterLeak.
  ///
  /// In en, this message translates to:
  /// **'Water leak'**
  String get hazardWaterLeak;

  /// No description provided for @hazardSmoke.
  ///
  /// In en, this message translates to:
  /// **'Smoke / particulates'**
  String get hazardSmoke;

  /// No description provided for @stateNormal.
  ///
  /// In en, this message translates to:
  /// **'normal'**
  String get stateNormal;

  /// No description provided for @stateDetection.
  ///
  /// In en, this message translates to:
  /// **'detection'**
  String get stateDetection;

  /// No description provided for @stateVerification.
  ///
  /// In en, this message translates to:
  /// **'verification'**
  String get stateVerification;

  /// No description provided for @stateAlarm.
  ///
  /// In en, this message translates to:
  /// **'alarm'**
  String get stateAlarm;

  /// No description provided for @stateEscalation.
  ///
  /// In en, this message translates to:
  /// **'escalation'**
  String get stateEscalation;

  /// No description provided for @stateEvacuation.
  ///
  /// In en, this message translates to:
  /// **'evacuation'**
  String get stateEvacuation;

  /// No description provided for @stateResolution.
  ///
  /// In en, this message translates to:
  /// **'resolved'**
  String get stateResolution;

  /// No description provided for @stateFalseAlarm.
  ///
  /// In en, this message translates to:
  /// **'false alarm'**
  String get stateFalseAlarm;

  /// No description provided for @levelOk.
  ///
  /// In en, this message translates to:
  /// **'ok'**
  String get levelOk;

  /// No description provided for @levelAttention.
  ///
  /// In en, this message translates to:
  /// **'attention'**
  String get levelAttention;

  /// No description provided for @levelDanger.
  ///
  /// In en, this message translates to:
  /// **'danger'**
  String get levelDanger;

  /// No description provided for @levelUnknown.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get levelUnknown;

  /// No description provided for @statusOffline.
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get statusOffline;

  /// No description provided for @statusNoData.
  ///
  /// In en, this message translates to:
  /// **'no data'**
  String get statusNoData;

  /// No description provided for @occupied.
  ///
  /// In en, this message translates to:
  /// **'occupied'**
  String get occupied;

  /// Zone occupancy pill: nobody detected in the zone.
  ///
  /// In en, this message translates to:
  /// **'empty'**
  String get empty;

  /// No description provided for @homeStatus.
  ///
  /// In en, this message translates to:
  /// **'Home status'**
  String get homeStatus;

  /// No description provided for @buildingSensors.
  ///
  /// In en, this message translates to:
  /// **'Building sensors'**
  String get buildingSensors;

  /// No description provided for @statusNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get statusNeedsAttention;

  /// No description provided for @statusDanger.
  ///
  /// In en, this message translates to:
  /// **'Danger'**
  String get statusDanger;

  /// No description provided for @statusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Status unknown'**
  String get statusUnknown;

  /// No description provided for @sensorsOnline.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =1{{online} of 1 sensor online} other{{online} of {total} sensors online}}'**
  String sensorsOnline(int online, int total);

  /// No description provided for @activeIncidentCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 active incident} other{{count} active incidents}}'**
  String activeIncidentCount(int count);

  /// No description provided for @noRecentData.
  ///
  /// In en, this message translates to:
  /// **'No recent data'**
  String get noRecentData;

  /// No description provided for @sensorOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get sensorOffline;

  /// No description provided for @lastSeen.
  ///
  /// In en, this message translates to:
  /// **'{status} · last seen {when}'**
  String lastSeen(String status, String when);

  /// No description provided for @kindAir.
  ///
  /// In en, this message translates to:
  /// **'Air sensor'**
  String get kindAir;

  /// No description provided for @kindWater.
  ///
  /// In en, this message translates to:
  /// **'Water sensor'**
  String get kindWater;

  /// No description provided for @kindSensor.
  ///
  /// In en, this message translates to:
  /// **'Sensor'**
  String get kindSensor;

  /// No description provided for @whatToDo.
  ///
  /// In en, this message translates to:
  /// **'What to do'**
  String get whatToDo;

  /// No description provided for @indicatorAirQuality.
  ///
  /// In en, this message translates to:
  /// **'Air quality'**
  String get indicatorAirQuality;

  /// No description provided for @indicatorCo.
  ///
  /// In en, this message translates to:
  /// **'Carbon monoxide'**
  String get indicatorCo;

  /// No description provided for @indicatorGas.
  ///
  /// In en, this message translates to:
  /// **'Gas'**
  String get indicatorGas;

  /// No description provided for @indicatorComfort.
  ///
  /// In en, this message translates to:
  /// **'Comfort'**
  String get indicatorComfort;

  /// No description provided for @indicatorOccupancy.
  ///
  /// In en, this message translates to:
  /// **'Occupancy'**
  String get indicatorOccupancy;

  /// No description provided for @indicatorLeak.
  ///
  /// In en, this message translates to:
  /// **'Water leak'**
  String get indicatorLeak;

  /// No description provided for @indicatorValve.
  ///
  /// In en, this message translates to:
  /// **'Water valve'**
  String get indicatorValve;

  /// No description provided for @trendRising.
  ///
  /// In en, this message translates to:
  /// **'rising'**
  String get trendRising;

  /// No description provided for @trendFalling.
  ///
  /// In en, this message translates to:
  /// **'falling'**
  String get trendFalling;

  /// No description provided for @trendStable.
  ///
  /// In en, this message translates to:
  /// **'stable'**
  String get trendStable;

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

  /// No description provided for @hubUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Can\'t reach the hub right now. Pull down to retry.'**
  String get hubUnreachable;

  /// No description provided for @noSensorsConnected.
  ///
  /// In en, this message translates to:
  /// **'No sensors connected'**
  String get noSensorsConnected;

  /// No description provided for @noSensorsHint.
  ///
  /// In en, this message translates to:
  /// **'Sensor status appears here once a Canary device joins the hub.'**
  String get noSensorsHint;

  /// No description provided for @refreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t refresh sensor status'**
  String get refreshFailed;

  /// No description provided for @refreshFailedShowingFrom.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t refresh · showing status from {time}'**
  String refreshFailedShowingFrom(String time);

  /// No description provided for @timeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get timeJustNow;

  /// No description provided for @minutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min ago'**
  String minutesAgo(int minutes);

  /// No description provided for @hoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{hours, plural, other{{hours} h ago}}'**
  String hoursAgo(int hours);

  /// No description provided for @offlineShowingSavedRoute.
  ///
  /// In en, this message translates to:
  /// **'Offline · showing saved route'**
  String get offlineShowingSavedRoute;

  /// No description provided for @minimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get minimize;

  /// No description provided for @dontGas.
  ///
  /// In en, this message translates to:
  /// **'Don\'t use the lift, light switches, or open flames.'**
  String get dontGas;

  /// No description provided for @dontCo.
  ///
  /// In en, this message translates to:
  /// **'Don\'t stay inside. Get to fresh air now.'**
  String get dontCo;

  /// No description provided for @dontSmoke.
  ///
  /// In en, this message translates to:
  /// **'Stay low under smoke. Don\'t use the lift.'**
  String get dontSmoke;

  /// No description provided for @dontWaterLeak.
  ///
  /// In en, this message translates to:
  /// **'Don\'t touch electrical devices or switches near water.'**
  String get dontWaterLeak;

  /// No description provided for @dontDefault.
  ///
  /// In en, this message translates to:
  /// **'Don\'t use the lift.'**
  String get dontDefault;

  /// No description provided for @routeCrossesHazard.
  ///
  /// In en, this message translates to:
  /// **'This route passes near the hazard. Use another marked exit if you can, and call 112.'**
  String get routeCrossesHazard;

  /// No description provided for @routeUnchecked.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t check this route against the hazard. Follow the marked exits, stay away from the hazard, and call 112 if unsure.'**
  String get routeUnchecked;

  /// No description provided for @evacuationRoute.
  ///
  /// In en, this message translates to:
  /// **'Evacuation route'**
  String get evacuationRoute;

  /// No description provided for @useNearestExit.
  ///
  /// In en, this message translates to:
  /// **'Use the nearest marked exit'**
  String get useNearestExit;

  /// No description provided for @useNearestExitDetail.
  ///
  /// In en, this message translates to:
  /// **'Take the stairs (not the lift) to the outdoor assembly point. Do not return inside.'**
  String get useNearestExitDetail;

  /// No description provided for @checkInSent.
  ///
  /// In en, this message translates to:
  /// **'Check-in sent: {status}'**
  String checkInSent(String status);

  /// No description provided for @checkInQueued.
  ///
  /// In en, this message translates to:
  /// **'Offline — check-in queued, will send automatically'**
  String get checkInQueued;

  /// No description provided for @dial112.
  ///
  /// In en, this message translates to:
  /// **'Dial 112 on your phone'**
  String get dial112;

  /// No description provided for @checkedIn.
  ///
  /// In en, this message translates to:
  /// **'Checked in: {status}'**
  String checkedIn(String status);

  /// No description provided for @change.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get change;

  /// No description provided for @imOutAndSafe.
  ///
  /// In en, this message translates to:
  /// **'I\'m out and safe'**
  String get imOutAndSafe;

  /// No description provided for @iNeedHelp.
  ///
  /// In en, this message translates to:
  /// **'I need help'**
  String get iNeedHelp;

  /// No description provided for @call112.
  ///
  /// In en, this message translates to:
  /// **'Call 112'**
  String get call112;

  /// No description provided for @imSafeStillInside.
  ///
  /// In en, this message translates to:
  /// **'I\'m safe but still inside'**
  String get imSafeStillInside;

  /// No description provided for @hazardCleared.
  ///
  /// In en, this message translates to:
  /// **'The hazard has cleared.'**
  String get hazardCleared;

  /// No description provided for @returnAction.
  ///
  /// In en, this message translates to:
  /// **'Return'**
  String get returnAction;

  /// No description provided for @startHere.
  ///
  /// In en, this message translates to:
  /// **'Start here'**
  String get startHere;

  /// No description provided for @avoidZone.
  ///
  /// In en, this message translates to:
  /// **'Avoid: {zone}'**
  String avoidZone(String zone);

  /// Screen-reader label for one evacuation step.
  ///
  /// In en, this message translates to:
  /// **'Step {step} of {total}: {label}.'**
  String routeStep(int step, int total, String label);

  /// No description provided for @evacuationOrdered.
  ///
  /// In en, this message translates to:
  /// **'Evacuation ordered'**
  String get evacuationOrdered;

  /// No description provided for @incidentResolved.
  ///
  /// In en, this message translates to:
  /// **'Incident resolved'**
  String get incidentResolved;

  /// No description provided for @incidentDismissed.
  ///
  /// In en, this message translates to:
  /// **'Incident dismissed'**
  String get incidentDismissed;

  /// No description provided for @actionFailed.
  ///
  /// In en, this message translates to:
  /// **'Action failed: {reason}'**
  String actionFailed(String reason);

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

  /// No description provided for @metricOccupants.
  ///
  /// In en, this message translates to:
  /// **'Occupants'**
  String get metricOccupants;

  /// No description provided for @metricAccounted.
  ///
  /// In en, this message translates to:
  /// **'Accounted'**
  String get metricAccounted;

  /// No description provided for @metricUnaccounted.
  ///
  /// In en, this message translates to:
  /// **'Unaccounted'**
  String get metricUnaccounted;

  /// No description provided for @metricNeedHelp.
  ///
  /// In en, this message translates to:
  /// **'Need help'**
  String get metricNeedHelp;

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

  /// No description provided for @noResidentsRegistered.
  ///
  /// In en, this message translates to:
  /// **'No residents registered.'**
  String get noResidentsRegistered;

  /// No description provided for @rosterNeedsHelp.
  ///
  /// In en, this message translates to:
  /// **'NEEDS HELP'**
  String get rosterNeedsHelp;

  /// No description provided for @rosterSafeOutside.
  ///
  /// In en, this message translates to:
  /// **'Safe — out'**
  String get rosterSafeOutside;

  /// No description provided for @rosterSafeInside.
  ///
  /// In en, this message translates to:
  /// **'Safe — in'**
  String get rosterSafeInside;

  /// No description provided for @rosterNoResponse.
  ///
  /// In en, this message translates to:
  /// **'No response'**
  String get rosterNoResponse;

  /// No description provided for @rosterAwaiting.
  ///
  /// In en, this message translates to:
  /// **'Awaiting'**
  String get rosterAwaiting;

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

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'My account'**
  String get account;

  /// No description provided for @roleResident.
  ///
  /// In en, this message translates to:
  /// **'Resident'**
  String get roleResident;

  /// No description provided for @roleManager.
  ///
  /// In en, this message translates to:
  /// **'Building manager'**
  String get roleManager;

  /// No description provided for @roleDispatcher.
  ///
  /// In en, this message translates to:
  /// **'Dispatcher'**
  String get roleDispatcher;

  /// No description provided for @roleAdmin.
  ///
  /// In en, this message translates to:
  /// **'System admin'**
  String get roleAdmin;

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

  /// No description provided for @sharePresenceDetail.
  ///
  /// In en, this message translates to:
  /// **'Lets responders better account for who is inside. Anonymous; used only during an active incident.'**
  String get sharePresenceDetail;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @aboutAppName.
  ///
  /// In en, this message translates to:
  /// **'Canary resident'**
  String get aboutAppName;

  /// No description provided for @aboutDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'v{version} — advisory safety app. Not a substitute for certified alarms.'**
  String aboutDisclaimer(String version);

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

  /// No description provided for @notifAlarmTitle.
  ///
  /// In en, this message translates to:
  /// **'{hazard} ALARM'**
  String notifAlarmTitle(String hazard);

  /// No description provided for @notifAlarmBody.
  ///
  /// In en, this message translates to:
  /// **'{hazard} detected. Prepare to evacuate. Follow guidance.'**
  String notifAlarmBody(String hazard);

  /// No description provided for @notifAlarmBodyWaterLeak.
  ///
  /// In en, this message translates to:
  /// **'Water leak detected. If a shut-off valve is fitted, it closed automatically. Avoid the area and check the unit.'**
  String get notifAlarmBodyWaterLeak;

  /// No description provided for @notifAlarmBodySmoke.
  ///
  /// In en, this message translates to:
  /// **'Smoke or heavy particulates detected. Check for smoke or fire and ventilate if safe. If there is a fire, leave and call 112.'**
  String get notifAlarmBodySmoke;

  /// No description provided for @notifEvacuateTitle.
  ///
  /// In en, this message translates to:
  /// **'EVACUATE NOW — {hazard}'**
  String notifEvacuateTitle(String hazard);

  /// No description provided for @notifEvacuateBody.
  ///
  /// In en, this message translates to:
  /// **'Evacuate via the safe route to the assembly point. Check in when safe.'**
  String get notifEvacuateBody;

  /// No description provided for @notifEscalatedTitle.
  ///
  /// In en, this message translates to:
  /// **'{hazard} escalated'**
  String notifEscalatedTitle(String hazard);

  /// No description provided for @notifEscalatedBody.
  ///
  /// In en, this message translates to:
  /// **'Incident escalated to monitoring/emergency partners.'**
  String get notifEscalatedBody;

  /// No description provided for @notifAlertTitle.
  ///
  /// In en, this message translates to:
  /// **'{hazard} alert'**
  String notifAlertTitle(String hazard);

  /// No description provided for @notifOpenForGuidance.
  ///
  /// In en, this message translates to:
  /// **'Open Canary for guidance.'**
  String get notifOpenForGuidance;

  /// No description provided for @pushFallbackTitle.
  ///
  /// In en, this message translates to:
  /// **'Canary alert'**
  String get pushFallbackTitle;

  /// No description provided for @measurements.
  ///
  /// In en, this message translates to:
  /// **'Measurements'**
  String get measurements;

  /// Sensor sheet range toggle: last hour.
  ///
  /// In en, this message translates to:
  /// **'1h'**
  String get rangeHourShort;

  /// No description provided for @range24hShort.
  ///
  /// In en, this message translates to:
  /// **'24h'**
  String get range24hShort;

  /// No description provided for @range7dShort.
  ///
  /// In en, this message translates to:
  /// **'7d'**
  String get range7dShort;

  /// No description provided for @rangeHour.
  ///
  /// In en, this message translates to:
  /// **'Last hour'**
  String get rangeHour;

  /// No description provided for @range24h.
  ///
  /// In en, this message translates to:
  /// **'24 hours'**
  String get range24h;

  /// No description provided for @range7d.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get range7d;

  /// No description provided for @inLastHour.
  ///
  /// In en, this message translates to:
  /// **'in the last hour'**
  String get inLastHour;

  /// No description provided for @inLast24h.
  ///
  /// In en, this message translates to:
  /// **'in the last 24 hours'**
  String get inLast24h;

  /// No description provided for @inLast7d.
  ///
  /// In en, this message translates to:
  /// **'in the last 7 days'**
  String get inLast7d;

  /// Shown with ≈ (approximate).
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get tileTemperature;

  /// Shown with ≈ (approximate).
  ///
  /// In en, this message translates to:
  /// **'Humidity'**
  String get tileHumidity;

  /// No description provided for @tileFineParticles.
  ///
  /// In en, this message translates to:
  /// **'Fine particles (PM2.5)'**
  String get tileFineParticles;

  /// No description provided for @tileParticles.
  ///
  /// In en, this message translates to:
  /// **'Particles (PM10)'**
  String get tileParticles;

  /// No description provided for @tileGas.
  ///
  /// In en, this message translates to:
  /// **'Gas level'**
  String get tileGas;

  /// No description provided for @tileLeak.
  ///
  /// In en, this message translates to:
  /// **'Leak'**
  String get tileLeak;

  /// No description provided for @tileValve.
  ///
  /// In en, this message translates to:
  /// **'Valve'**
  String get tileValve;

  /// No description provided for @chipAir.
  ///
  /// In en, this message translates to:
  /// **'Air'**
  String get chipAir;

  /// No description provided for @chipWater.
  ///
  /// In en, this message translates to:
  /// **'Water'**
  String get chipWater;

  /// No description provided for @noLeaks.
  ///
  /// In en, this message translates to:
  /// **'No leaks'**
  String get noLeaks;

  /// Under the gas %: the share of the device's warning threshold.
  ///
  /// In en, this message translates to:
  /// **'of warning level'**
  String get gasOfWarning;

  /// No description provided for @verdictGood.
  ///
  /// In en, this message translates to:
  /// **'Good'**
  String get verdictGood;

  /// No description provided for @verdictModerate.
  ///
  /// In en, this message translates to:
  /// **'Moderate'**
  String get verdictModerate;

  /// No description provided for @verdictPoor.
  ///
  /// In en, this message translates to:
  /// **'Poor'**
  String get verdictPoor;

  /// No description provided for @verdictDanger.
  ///
  /// In en, this message translates to:
  /// **'Danger'**
  String get verdictDanger;

  /// No description provided for @verdictSafe.
  ///
  /// In en, this message translates to:
  /// **'Safe'**
  String get verdictSafe;

  /// No description provided for @verdictElevated.
  ///
  /// In en, this message translates to:
  /// **'Elevated'**
  String get verdictElevated;

  /// No description provided for @verdictNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get verdictNormal;

  /// No description provided for @verdictCool.
  ///
  /// In en, this message translates to:
  /// **'Cool'**
  String get verdictCool;

  /// No description provided for @verdictComfortable.
  ///
  /// In en, this message translates to:
  /// **'Comfortable'**
  String get verdictComfortable;

  /// No description provided for @verdictWarm.
  ///
  /// In en, this message translates to:
  /// **'Warm'**
  String get verdictWarm;

  /// No description provided for @verdictDryAir.
  ///
  /// In en, this message translates to:
  /// **'Dry air'**
  String get verdictDryAir;

  /// No description provided for @verdictHumidityOk.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get verdictHumidityOk;

  /// No description provided for @verdictHumid.
  ///
  /// In en, this message translates to:
  /// **'Humid'**
  String get verdictHumid;

  /// No description provided for @verdictDry.
  ///
  /// In en, this message translates to:
  /// **'Dry'**
  String get verdictDry;

  /// No description provided for @verdictLeak.
  ///
  /// In en, this message translates to:
  /// **'Leak'**
  String get verdictLeak;

  /// No description provided for @approx.
  ///
  /// In en, this message translates to:
  /// **'Approx.'**
  String get approx;

  /// No description provided for @warmingUp.
  ///
  /// In en, this message translates to:
  /// **'Sensor warming up'**
  String get warmingUp;

  /// No description provided for @warmingUpShort.
  ///
  /// In en, this message translates to:
  /// **'Warming up'**
  String get warmingUpShort;

  /// No description provided for @noReadings.
  ///
  /// In en, this message translates to:
  /// **'No readings {range}.'**
  String noReadings(String range);

  /// No description provided for @historyFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the measurements.'**
  String get historyFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @lastLeak.
  ///
  /// In en, this message translates to:
  /// **'Last leak: {time}'**
  String lastLeak(String time);

  /// No description provided for @noLeakIn.
  ///
  /// In en, this message translates to:
  /// **'No leak {range}'**
  String noLeakIn(String range);

  /// No description provided for @approxNote.
  ///
  /// In en, this message translates to:
  /// **'≈ Approx.: measured inside the sensor, so it may differ slightly from the room.'**
  String get approxNote;

  /// No description provided for @analysisDetails.
  ///
  /// In en, this message translates to:
  /// **'Analysis details'**
  String get analysisDetails;

  /// Screen-reader summary of a sensor tile.
  ///
  /// In en, this message translates to:
  /// **'{label}: {value}, {word}. Between {min} and {max} {range}.'**
  String tileSemantics(String label, String value, String word, String min,
      String max, String range);

  /// No description provided for @spokenTemperature.
  ///
  /// In en, this message translates to:
  /// **'about {value} degrees'**
  String spokenTemperature(String value);

  /// No description provided for @spokenHumidity.
  ///
  /// In en, this message translates to:
  /// **'about {value} percent'**
  String spokenHumidity(String value);

  /// No description provided for @spokenParticles.
  ///
  /// In en, this message translates to:
  /// **'{value} micrograms per cubic metre'**
  String spokenParticles(String value);

  /// No description provided for @spokenCo.
  ///
  /// In en, this message translates to:
  /// **'{value} parts per million'**
  String spokenCo(String value);

  /// No description provided for @spokenGas.
  ///
  /// In en, this message translates to:
  /// **'{value} percent of warning level'**
  String spokenGas(String value);

  /// No description provided for @careProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'Emergency profile'**
  String get careProfileTitle;

  /// No description provided for @careProfileSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Help first for anyone at home who can\'t get out alone'**
  String get careProfileSettingsSubtitle;

  /// No description provided for @careEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'If someone at home can\'t get out alone in an emergency (a grandparent, a small child), add them here. The dispatcher and the building manager see this only during an emergency, so that person is helped first.'**
  String get careEmptyBody;

  /// No description provided for @careAddPerson.
  ///
  /// In en, this message translates to:
  /// **'Add person'**
  String get careAddPerson;

  /// Badge on the resident's own care profile.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get careSelfBadge;

  /// No description provided for @careForMe.
  ///
  /// In en, this message translates to:
  /// **'For me'**
  String get careForMe;

  /// No description provided for @careForOther.
  ///
  /// In en, this message translates to:
  /// **'Someone else at home'**
  String get careForOther;

  /// No description provided for @careName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get careName;

  /// No description provided for @careNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a name'**
  String get careNameRequired;

  /// No description provided for @careUnit.
  ///
  /// In en, this message translates to:
  /// **'Apartment'**
  String get careUnit;

  /// No description provided for @careNeedsLabel.
  ///
  /// In en, this message translates to:
  /// **'What help is needed?'**
  String get careNeedsLabel;

  /// No description provided for @careNote.
  ///
  /// In en, this message translates to:
  /// **'Note (optional)'**
  String get careNote;

  /// No description provided for @careNoteHint.
  ///
  /// In en, this message translates to:
  /// **'E.g. uses a walking frame, sleeps in the back room'**
  String get careNoteHint;

  /// No description provided for @careConsent.
  ///
  /// In en, this message translates to:
  /// **'I agree that this health information may be seen by the dispatcher and the building manager, only during an emergency, so that the person who needs help is helped first. I can delete it at any time. Every access is logged.'**
  String get careConsent;

  /// No description provided for @careSaveHint.
  ///
  /// In en, this message translates to:
  /// **'To save: tick the agreement and choose a need or write a note.'**
  String get careSaveHint;

  /// No description provided for @careSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get careSave;

  /// No description provided for @careNewTitle.
  ///
  /// In en, this message translates to:
  /// **'New profile'**
  String get careNewTitle;

  /// No description provided for @careEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get careEditTitle;

  /// No description provided for @careDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete profile'**
  String get careDelete;

  /// No description provided for @careDeleteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete the profile?'**
  String get careDeleteConfirmTitle;

  /// No description provided for @careDeleteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'The information is deleted permanently.'**
  String get careDeleteConfirmBody;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @careSaved.
  ///
  /// In en, this message translates to:
  /// **'Profile saved'**
  String get careSaved;

  /// No description provided for @careDeleted.
  ///
  /// In en, this message translates to:
  /// **'Profile deleted'**
  String get careDeleted;

  /// No description provided for @careNotActive.
  ///
  /// In en, this message translates to:
  /// **'This feature isn\'t active on this hub.'**
  String get careNotActive;

  /// No description provided for @careSelfExists.
  ///
  /// In en, this message translates to:
  /// **'You already have a profile for yourself.'**
  String get careSelfExists;

  /// No description provided for @careUnitNotYours.
  ///
  /// In en, this message translates to:
  /// **'This apartment isn\'t linked to your account.'**
  String get careUnitNotYours;

  /// No description provided for @careInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check the details: choose at least one need or write a note.'**
  String get careInvalid;

  /// No description provided for @careNoUnit.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t find your apartment. Try again later.'**
  String get careNoUnit;

  /// No description provided for @careLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the emergency profiles.'**
  String get careLoadFailed;

  /// No description provided for @carePrivacyNote.
  ///
  /// In en, this message translates to:
  /// **'Stored only on the building\'s hub, not on this phone. Shown only during an emergency. You can delete it at any time.'**
  String get carePrivacyNote;

  /// No description provided for @needReducedMobility.
  ///
  /// In en, this message translates to:
  /// **'Reduced mobility'**
  String get needReducedMobility;

  /// No description provided for @needWheelchair.
  ///
  /// In en, this message translates to:
  /// **'Wheelchair user'**
  String get needWheelchair;

  /// No description provided for @needBedridden.
  ///
  /// In en, this message translates to:
  /// **'Bedridden'**
  String get needBedridden;

  /// No description provided for @needHearingImpaired.
  ///
  /// In en, this message translates to:
  /// **'Can\'t hear the alarm'**
  String get needHearingImpaired;

  /// No description provided for @needVisuallyImpaired.
  ///
  /// In en, this message translates to:
  /// **'Blind or low vision'**
  String get needVisuallyImpaired;

  /// No description provided for @needMedicalDevice.
  ///
  /// In en, this message translates to:
  /// **'Oxygen or medical equipment'**
  String get needMedicalDevice;

  /// No description provided for @needYoungChild.
  ///
  /// In en, this message translates to:
  /// **'Young child'**
  String get needYoungChild;

  /// No description provided for @needPet.
  ///
  /// In en, this message translates to:
  /// **'Pet'**
  String get needPet;

  /// No description provided for @careHintTitle.
  ///
  /// In en, this message translates to:
  /// **'Someone at home needs help getting out?'**
  String get careHintTitle;

  /// No description provided for @careHintAction.
  ///
  /// In en, this message translates to:
  /// **'Add an emergency profile'**
  String get careHintAction;

  /// No description provided for @householdTitle.
  ///
  /// In en, this message translates to:
  /// **'Who else is at home?'**
  String get householdTitle;

  /// No description provided for @householdOut.
  ///
  /// In en, this message translates to:
  /// **'Outside'**
  String get householdOut;

  /// No description provided for @householdInside.
  ///
  /// In en, this message translates to:
  /// **'Still inside'**
  String get householdInside;

  /// No description provided for @householdNeedsHelp.
  ///
  /// In en, this message translates to:
  /// **'Needs help'**
  String get householdNeedsHelp;

  /// No description provided for @householdSent.
  ///
  /// In en, this message translates to:
  /// **'Sent: {status}'**
  String householdSent(String status);

  /// No description provided for @householdSending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get householdSending;

  /// No description provided for @householdFailed.
  ///
  /// In en, this message translates to:
  /// **'Not sent — no connection.'**
  String get householdFailed;

  /// No description provided for @householdLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your apartment.'**
  String get householdLoadFailed;

  /// No description provided for @householdPersonSemantics.
  ///
  /// In en, this message translates to:
  /// **'{name}, where is this person now?'**
  String householdPersonSemantics(String name);

  /// No description provided for @accountName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get accountName;

  /// No description provided for @accountPhone.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get accountPhone;

  /// No description provided for @accountPhoneHint.
  ///
  /// In en, this message translates to:
  /// **'The dispatcher calls you on this number in an emergency'**
  String get accountPhoneHint;

  /// No description provided for @accountEmail.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get accountEmail;

  /// No description provided for @accountRole.
  ///
  /// In en, this message translates to:
  /// **'Role'**
  String get accountRole;

  /// No description provided for @accountSaved.
  ///
  /// In en, this message translates to:
  /// **'Account saved'**
  String get accountSaved;

  /// No description provided for @accountNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Editing your account isn\'t available on this hub yet.'**
  String get accountNotAvailable;

  /// No description provided for @accountLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your account.'**
  String get accountLoadFailed;

  /// No description provided for @accountPhoneInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid phone number, e.g. 0722 123 456'**
  String get accountPhoneInvalid;

  /// No description provided for @accountEmailInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address'**
  String get accountEmailInvalid;

  /// No description provided for @accountReadOnlyNote.
  ///
  /// In en, this message translates to:
  /// **'Username, role and apartment are set by the building manager.'**
  String get accountReadOnlyNote;

  /// No description provided for @accountEditHint.
  ///
  /// In en, this message translates to:
  /// **'Edit your name, phone and email'**
  String get accountEditHint;

  /// No description provided for @chipCoHigh.
  ///
  /// In en, this message translates to:
  /// **'High CO'**
  String get chipCoHigh;

  /// No description provided for @chipCoDanger.
  ///
  /// In en, this message translates to:
  /// **'Dangerous CO'**
  String get chipCoDanger;

  /// No description provided for @chipGasHigh.
  ///
  /// In en, this message translates to:
  /// **'High gas level'**
  String get chipGasHigh;

  /// No description provided for @chipGasDanger.
  ///
  /// In en, this message translates to:
  /// **'Dangerous gas level'**
  String get chipGasDanger;

  /// No description provided for @verifyingTitle.
  ///
  /// In en, this message translates to:
  /// **'Checking a possible problem'**
  String get verifyingTitle;

  /// No description provided for @verifyingCalm.
  ///
  /// In en, this message translates to:
  /// **'No need to leave yet. We\'ll tell you right away if you should.'**
  String get verifyingCalm;

  /// No description provided for @attentionBody.
  ///
  /// In en, this message translates to:
  /// **'No active hazard. See the room marked below.'**
  String get attentionBody;

  /// No description provided for @dangerBody.
  ///
  /// In en, this message translates to:
  /// **'Check the room marked below and follow the advice.'**
  String get dangerBody;

  /// No description provided for @statusUnknownBody.
  ///
  /// In en, this message translates to:
  /// **'The sensors haven\'t reported yet. Their status appears here as soon as they do.'**
  String get statusUnknownBody;

  /// No description provided for @healthImportButton.
  ///
  /// In en, this message translates to:
  /// **'Import from Health (Apple)'**
  String get healthImportButton;

  /// No description provided for @healthImporting.
  ///
  /// In en, this message translates to:
  /// **'Reading Health data…'**
  String get healthImporting;

  /// No description provided for @healthFoundTitle.
  ///
  /// In en, this message translates to:
  /// **'Found in Health:'**
  String get healthFoundTitle;

  /// No description provided for @healthNothingFound.
  ///
  /// In en, this message translates to:
  /// **'No relevant data found. You can fill this in yourself.'**
  String get healthNothingFound;

  /// No description provided for @healthAccessNote.
  ///
  /// In en, this message translates to:
  /// **'iOS doesn\'t tell apps whether access was refused. If you didn\'t allow it, turn it on in Settings > Health > Data Access & Devices.'**
  String get healthAccessNote;

  /// No description provided for @healthUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Health data isn\'t available on this device.'**
  String get healthUnavailable;

  /// No description provided for @healthReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t read data from Health. You can fill this in yourself.'**
  String get healthReadFailed;

  /// No description provided for @healthFromProfile.
  ///
  /// In en, this message translates to:
  /// **'from the Health profile'**
  String get healthFromProfile;

  /// No description provided for @healthFromSteadiness.
  ///
  /// In en, this message translates to:
  /// **'walking steadiness {value} %'**
  String healthFromSteadiness(String value);

  /// No description provided for @healthFromAudiogram.
  ///
  /// In en, this message translates to:
  /// **'audiogram: {value} dB in the better ear'**
  String healthFromAudiogram(String value);

  /// No description provided for @healthAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get healthAdd;

  /// No description provided for @healthPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Read only on this phone. Nothing is saved until you save the profile with your consent.'**
  String get healthPrivacy;

  /// No description provided for @healthSuggestionSemantics.
  ///
  /// In en, this message translates to:
  /// **'{need}, {source}. Add to the profile?'**
  String healthSuggestionSemantics(String need, String source);

  /// No description provided for @range6hShort.
  ///
  /// In en, this message translates to:
  /// **'6h'**
  String get range6hShort;

  /// No description provided for @range6h.
  ///
  /// In en, this message translates to:
  /// **'6 hours'**
  String get range6h;

  /// No description provided for @inLast6h.
  ///
  /// In en, this message translates to:
  /// **'in the last 6 hours'**
  String get inLast6h;

  /// No description provided for @chartThresholdWarn.
  ///
  /// In en, this message translates to:
  /// **'Warning level {value}'**
  String chartThresholdWarn(String value);

  /// No description provided for @chartThresholdDanger.
  ///
  /// In en, this message translates to:
  /// **'Danger level {value}'**
  String chartThresholdDanger(String value);

  /// No description provided for @chartNoData.
  ///
  /// In en, this message translates to:
  /// **'no data'**
  String get chartNoData;

  /// No description provided for @chartNow.
  ///
  /// In en, this message translates to:
  /// **'Now'**
  String get chartNow;

  /// No description provided for @chartMin.
  ///
  /// In en, this message translates to:
  /// **'Min'**
  String get chartMin;

  /// No description provided for @chartMean.
  ///
  /// In en, this message translates to:
  /// **'Average'**
  String get chartMean;

  /// No description provided for @chartMax.
  ///
  /// In en, this message translates to:
  /// **'Max'**
  String get chartMax;

  /// No description provided for @chartWhatMeans.
  ///
  /// In en, this message translates to:
  /// **'What does it mean?'**
  String get chartWhatMeans;

  /// No description provided for @chartHint.
  ///
  /// In en, this message translates to:
  /// **'Touch and drag on the chart to see the exact value.'**
  String get chartHint;

  /// No description provided for @chartAt.
  ///
  /// In en, this message translates to:
  /// **'At {time}: {value}'**
  String chartAt(String time, String value);

  /// No description provided for @chartPrevMetric.
  ///
  /// In en, this message translates to:
  /// **'Previous measurement'**
  String get chartPrevMetric;

  /// No description provided for @chartNextMetric.
  ///
  /// In en, this message translates to:
  /// **'Next measurement'**
  String get chartNextMetric;

  /// No description provided for @explainTemperature.
  ///
  /// In en, this message translates to:
  /// **'Measured inside the sensor, so it is approximate and may read a little warmer than the room.'**
  String get explainTemperature;

  /// No description provided for @explainHumidity.
  ///
  /// In en, this message translates to:
  /// **'Measured inside the sensor, approximate. Comfortable indoors: about 30–60 %.'**
  String get explainHumidity;

  /// No description provided for @explainPm25.
  ///
  /// In en, this message translates to:
  /// **'Fine dust from smoke, cooking or outside air. Lower is better; the sensor warns from {warn}.'**
  String explainPm25(String warn);

  /// No description provided for @explainPm10.
  ///
  /// In en, this message translates to:
  /// **'Coarser dust and pollen. The sensor warns from {warn}.'**
  String explainPm10(String warn);

  /// No description provided for @explainCo.
  ///
  /// In en, this message translates to:
  /// **'Carbon monoxide is a gas with no smell. The sensor alerts you from {warn}.'**
  String explainCo(String warn);

  /// No description provided for @explainGas.
  ///
  /// In en, this message translates to:
  /// **'% of the sensor\'s warning level, not a concentration. Above 100 % the sensor raises an alarm.'**
  String get explainGas;

  /// No description provided for @explainLeak.
  ///
  /// In en, this message translates to:
  /// **'Dry or wet, as the water sensor on the floor reports it.'**
  String get explainLeak;

  /// No description provided for @homeViewList.
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get homeViewList;

  /// No description provided for @homeViewSketch.
  ///
  /// In en, this message translates to:
  /// **'Sketch'**
  String get homeViewSketch;

  /// No description provided for @sketchCommonArea.
  ///
  /// In en, this message translates to:
  /// **'common area'**
  String get sketchCommonArea;

  /// No description provided for @sketchAvoid.
  ///
  /// In en, this message translates to:
  /// **'Avoid'**
  String get sketchAvoid;

  /// No description provided for @sensorCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 sensor} other{{count} sensors}}'**
  String sensorCount(int count);

  /// No description provided for @sketchNoPositions.
  ///
  /// In en, this message translates to:
  /// **'Room positions aren\'t known yet, so rooms are shown in order.'**
  String get sketchNoPositions;

  /// No description provided for @sketchHint.
  ///
  /// In en, this message translates to:
  /// **'A sketch of your rooms, not to scale. Tap a room for its sensors.'**
  String get sketchHint;

  /// No description provided for @householdSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'My apartment'**
  String get householdSettingsTitle;

  /// No description provided for @householdSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Who lives here, and invites'**
  String get householdSettingsSubtitle;

  /// No description provided for @householdMembers.
  ///
  /// In en, this message translates to:
  /// **'People with an account'**
  String get householdMembers;

  /// No description provided for @householdMemberSince.
  ///
  /// In en, this message translates to:
  /// **'since {date}'**
  String householdMemberSince(String date);

  /// No description provided for @householdPendingInvites.
  ///
  /// In en, this message translates to:
  /// **'Pending invites'**
  String get householdPendingInvites;

  /// No description provided for @householdExpires.
  ///
  /// In en, this message translates to:
  /// **'Expires: {when}'**
  String householdExpires(String when);

  /// No description provided for @householdInviteFor.
  ///
  /// In en, this message translates to:
  /// **'for {name}'**
  String householdInviteFor(String name);

  /// No description provided for @householdRevoke.
  ///
  /// In en, this message translates to:
  /// **'Cancel invite'**
  String get householdRevoke;

  /// No description provided for @householdInviteSomeone.
  ///
  /// In en, this message translates to:
  /// **'Invite someone with an account'**
  String get householdInviteSomeone;

  /// No description provided for @householdLeave.
  ///
  /// In en, this message translates to:
  /// **'Leave the apartment'**
  String get householdLeave;

  /// No description provided for @householdLeaveTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave {unit}?'**
  String householdLeaveTitle(String unit);

  /// No description provided for @householdLeaveBody.
  ///
  /// In en, this message translates to:
  /// **'You will no longer see this apartment\'s sensors or get its alerts. The emergency profiles you created for it are deleted.'**
  String get householdLeaveBody;

  /// No description provided for @householdLeaveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get householdLeaveConfirm;

  /// No description provided for @householdLeft.
  ///
  /// In en, this message translates to:
  /// **'You left the apartment'**
  String get householdLeft;

  /// No description provided for @householdEmpty.
  ///
  /// In en, this message translates to:
  /// **'No apartment is linked to your account.'**
  String get householdEmpty;

  /// No description provided for @householdTooManyInvites.
  ///
  /// In en, this message translates to:
  /// **'There are already 5 pending invites. Cancel one first.'**
  String get householdTooManyInvites;

  /// No description provided for @inviteSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Invite link'**
  String get inviteSheetTitle;

  /// No description provided for @inviteCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get inviteCopy;

  /// No description provided for @inviteCopied.
  ///
  /// In en, this message translates to:
  /// **'Link copied'**
  String get inviteCopied;

  /// No description provided for @inviteSms.
  ///
  /// In en, this message translates to:
  /// **'Send by SMS'**
  String get inviteSms;

  /// No description provided for @inviteEmail.
  ///
  /// In en, this message translates to:
  /// **'Send by email'**
  String get inviteEmail;

  /// No description provided for @inviteExpiryHours.
  ///
  /// In en, this message translates to:
  /// **'{hours, plural, =1{Expires in 1 hour, single use.} other{Expires in {hours} hours, single use.}}'**
  String inviteExpiryHours(int hours);

  /// No description provided for @inviteMessage.
  ///
  /// In en, this message translates to:
  /// **'Join our apartment ({unit}) in Canary: {url}'**
  String inviteMessage(String unit, String url);

  /// No description provided for @inviteEmailSubject.
  ///
  /// In en, this message translates to:
  /// **'Invitation to Canary'**
  String get inviteEmailSubject;

  /// No description provided for @careInviteMember.
  ///
  /// In en, this message translates to:
  /// **'Has their own account? Send them an invite'**
  String get careInviteMember;

  /// No description provided for @inviteCodeEntry.
  ///
  /// In en, this message translates to:
  /// **'I have an invite code'**
  String get inviteCodeEntry;

  /// No description provided for @inviteCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Invite code'**
  String get inviteCodeLabel;

  /// No description provided for @inviteCodeHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the code or the whole link'**
  String get inviteCodeHint;

  /// No description provided for @inviteCodeInvalid.
  ///
  /// In en, this message translates to:
  /// **'That doesn\'t look like an invite code.'**
  String get inviteCodeInvalid;

  /// No description provided for @inviteContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get inviteContinue;

  /// No description provided for @inviteTitle.
  ///
  /// In en, this message translates to:
  /// **'Invitation'**
  String get inviteTitle;

  /// No description provided for @inviteFrom.
  ///
  /// In en, this message translates to:
  /// **'{inviter} invites you to join'**
  String inviteFrom(String inviter);

  /// No description provided for @inviteBuilding.
  ///
  /// In en, this message translates to:
  /// **'Building'**
  String get inviteBuilding;

  /// No description provided for @inviteFloor.
  ///
  /// In en, this message translates to:
  /// **'Floor'**
  String get inviteFloor;

  /// No description provided for @inviteCareOffer.
  ///
  /// In en, this message translates to:
  /// **'{inviter} created an emergency profile for you ({name}). Do you want to take it over?'**
  String inviteCareOffer(String inviter, String name);

  /// No description provided for @inviteTakeOver.
  ///
  /// In en, this message translates to:
  /// **'Yes, take over this profile'**
  String get inviteTakeOver;

  /// No description provided for @inviteAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get inviteAccept;

  /// No description provided for @inviteDecline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get inviteDecline;

  /// No description provided for @inviteAccepted.
  ///
  /// In en, this message translates to:
  /// **'You joined {unit}'**
  String inviteAccepted(String unit);

  /// No description provided for @inviteInvalid.
  ///
  /// In en, this message translates to:
  /// **'This invite is no longer valid (expired, used or mistyped).'**
  String get inviteInvalid;

  /// No description provided for @inviteStaff.
  ///
  /// In en, this message translates to:
  /// **'Only residents can join an apartment.'**
  String get inviteStaff;

  /// No description provided for @inviteConflict.
  ///
  /// In en, this message translates to:
  /// **'You can\'t accept your own invite, or you already have an emergency profile for yourself.'**
  String get inviteConflict;

  /// No description provided for @inviteNeedsConsent.
  ///
  /// In en, this message translates to:
  /// **'Tick the agreement to take over the profile.'**
  String get inviteNeedsConsent;

  /// No description provided for @inviteTooMany.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Try again later.'**
  String get inviteTooMany;

  /// No description provided for @inviteLoginFirst.
  ///
  /// In en, this message translates to:
  /// **'Sign in to accept the invitation.'**
  String get inviteLoginFirst;

  /// No description provided for @inviteLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading the invitation…'**
  String get inviteLoading;

  /// No description provided for @testSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Test the sensor'**
  String get testSectionTitle;

  /// No description provided for @testAlarmButton.
  ///
  /// In en, this message translates to:
  /// **'Test the alarm (4 s)'**
  String get testAlarmButton;

  /// No description provided for @testAlarmHint.
  ///
  /// In en, this message translates to:
  /// **'The sensor will beep and flash for 4 seconds.'**
  String get testAlarmHint;

  /// No description provided for @silenceAlarmButton.
  ///
  /// In en, this message translates to:
  /// **'Silence the alarm'**
  String get silenceAlarmButton;

  /// No description provided for @closeValveButton.
  ///
  /// In en, this message translates to:
  /// **'Close the valve'**
  String get closeValveButton;

  /// No description provided for @openValveButton.
  ///
  /// In en, this message translates to:
  /// **'Open the valve'**
  String get openValveButton;

  /// No description provided for @closeValveConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Close the valve?'**
  String get closeValveConfirmTitle;

  /// No description provided for @closeValveConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'The valve will shut off the water in the apartment until you open it again.'**
  String get closeValveConfirmBody;

  /// No description provided for @commonAreaTestNote.
  ///
  /// In en, this message translates to:
  /// **'Only the building manager can test sensors in common areas.'**
  String get commonAreaTestNote;

  /// No description provided for @testOfflineNote.
  ///
  /// In en, this message translates to:
  /// **'The sensor is offline. You can test it once it reconnects.'**
  String get testOfflineNote;

  /// No description provided for @runSent.
  ///
  /// In en, this message translates to:
  /// **'Sent…'**
  String get runSent;

  /// No description provided for @runAccepted.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get runAccepted;

  /// No description provided for @runRejected.
  ///
  /// In en, this message translates to:
  /// **'Refused: {reason}'**
  String runRejected(String reason);

  /// No description provided for @runRejectedPlain.
  ///
  /// In en, this message translates to:
  /// **'Refused'**
  String get runRejectedPlain;

  /// No description provided for @runTimeout.
  ///
  /// In en, this message translates to:
  /// **'No answer'**
  String get runTimeout;

  /// No description provided for @runTimeoutHint.
  ///
  /// In en, this message translates to:
  /// **'The sensor did not answer within 15 seconds.'**
  String get runTimeoutHint;

  /// No description provided for @runFailed.
  ///
  /// In en, this message translates to:
  /// **'Not sent: {reason}'**
  String runFailed(String reason);

  /// No description provided for @commandTest.
  ///
  /// In en, this message translates to:
  /// **'Alarm test'**
  String get commandTest;

  /// No description provided for @commandSilence.
  ///
  /// In en, this message translates to:
  /// **'Silence alarm'**
  String get commandSilence;

  /// No description provided for @commandOpen.
  ///
  /// In en, this message translates to:
  /// **'Open valve'**
  String get commandOpen;

  /// No description provided for @commandClose.
  ///
  /// In en, this message translates to:
  /// **'Close valve'**
  String get commandClose;

  /// No description provided for @cmdErrOffline.
  ///
  /// In en, this message translates to:
  /// **'the sensor is offline'**
  String get cmdErrOffline;

  /// No description provided for @cmdErrTooSoon.
  ///
  /// In en, this message translates to:
  /// **'wait a few seconds between commands'**
  String get cmdErrTooSoon;

  /// No description provided for @cmdErrNotYours.
  ///
  /// In en, this message translates to:
  /// **'this sensor is not in your apartment'**
  String get cmdErrNotYours;

  /// No description provided for @cmdErrInvalid.
  ///
  /// In en, this message translates to:
  /// **'this sensor does not take that command'**
  String get cmdErrInvalid;

  /// No description provided for @cmdErrForbidden.
  ///
  /// In en, this message translates to:
  /// **'your account cannot send commands'**
  String get cmdErrForbidden;

  /// No description provided for @detailSelfTest.
  ///
  /// In en, this message translates to:
  /// **'self-test started'**
  String get detailSelfTest;

  /// No description provided for @detailSilenced.
  ///
  /// In en, this message translates to:
  /// **'alarm silenced'**
  String get detailSilenced;

  /// No description provided for @detailSelfTestBusy.
  ///
  /// In en, this message translates to:
  /// **'a self-test is already running'**
  String get detailSelfTestBusy;

  /// No description provided for @detailAlarmInactive.
  ///
  /// In en, this message translates to:
  /// **'no active alarm'**
  String get detailAlarmInactive;

  /// No description provided for @detailOpen.
  ///
  /// In en, this message translates to:
  /// **'valve open'**
  String get detailOpen;

  /// No description provided for @detailClosed.
  ///
  /// In en, this message translates to:
  /// **'valve closed'**
  String get detailClosed;

  /// No description provided for @detailBusy.
  ///
  /// In en, this message translates to:
  /// **'the sensor is busy with another command'**
  String get detailBusy;

  /// No description provided for @detailInvalidCommand.
  ///
  /// In en, this message translates to:
  /// **'the sensor does not know this command'**
  String get detailInvalidCommand;

  /// No description provided for @detailSensorWet.
  ///
  /// In en, this message translates to:
  /// **'the sensor still detects water'**
  String get detailSensorWet;

  /// No description provided for @detailSensorUninitialized.
  ///
  /// In en, this message translates to:
  /// **'the sensor is still starting up'**
  String get detailSensorUninitialized;

  /// No description provided for @detailOtaActive.
  ///
  /// In en, this message translates to:
  /// **'the sensor is updating'**
  String get detailOtaActive;

  /// No description provided for @detailCommandRejected.
  ///
  /// In en, this message translates to:
  /// **'the sensor refused the command'**
  String get detailCommandRejected;

  /// No description provided for @detailPersistenceFailed.
  ///
  /// In en, this message translates to:
  /// **'the valve state could not be saved'**
  String get detailPersistenceFailed;

  /// No description provided for @lastTest.
  ///
  /// In en, this message translates to:
  /// **'Last test: {result} · {when}'**
  String lastTest(String result, String when);

  /// No description provided for @lastTestNone.
  ///
  /// In en, this message translates to:
  /// **'Not tested yet'**
  String get lastTestNone;

  /// No description provided for @lastTestAccepted.
  ///
  /// In en, this message translates to:
  /// **'passed'**
  String get lastTestAccepted;

  /// No description provided for @lastTestRejected.
  ///
  /// In en, this message translates to:
  /// **'refused'**
  String get lastTestRejected;

  /// No description provided for @lastTestTimeout.
  ///
  /// In en, this message translates to:
  /// **'no answer'**
  String get lastTestTimeout;

  /// No description provided for @lastTestSent.
  ///
  /// In en, this message translates to:
  /// **'in progress'**
  String get lastTestSent;

  /// No description provided for @testMySensors.
  ///
  /// In en, this message translates to:
  /// **'Test my sensors'**
  String get testMySensors;

  /// No description provided for @testMySensorsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Make each sensor beep for a moment'**
  String get testMySensorsSubtitle;

  /// No description provided for @testBuildingSensors.
  ///
  /// In en, this message translates to:
  /// **'Test sensors'**
  String get testBuildingSensors;

  /// No description provided for @testBuildingSensorsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Every sensor in the building, by room'**
  String get testBuildingSensorsSubtitle;

  /// No description provided for @testAllAlarms.
  ///
  /// In en, this message translates to:
  /// **'Test all alarms'**
  String get testAllAlarms;

  /// No description provided for @testAllHint.
  ///
  /// In en, this message translates to:
  /// **'Your apartment\'s air sensors beep one after another, 4 seconds each. Water valves are never closed.'**
  String get testAllHint;

  /// No description provided for @testAllRunning.
  ///
  /// In en, this message translates to:
  /// **'Testing {done} of {total}…'**
  String testAllRunning(int done, int total);

  /// No description provided for @testAllDone.
  ///
  /// In en, this message translates to:
  /// **'Done: {passed} of {total} passed'**
  String testAllDone(int passed, int total);

  /// No description provided for @testAllNoAir.
  ///
  /// In en, this message translates to:
  /// **'None of your air sensors is online right now.'**
  String get testAllNoAir;

  /// No description provided for @testAllNoAirHere.
  ///
  /// In en, this message translates to:
  /// **'None of the air sensors here is online right now.'**
  String get testAllNoAirHere;

  /// Test-all button with the picked apartment or room, e.g. 'Ap. 12'.
  ///
  /// In en, this message translates to:
  /// **'Test all alarms · {scope}'**
  String testAllAlarmsIn(String scope);

  /// No description provided for @testAllPickUnit.
  ///
  /// In en, this message translates to:
  /// **'Pick an apartment above to test all its alarms in one go.'**
  String get testAllPickUnit;

  /// No description provided for @scopeWholeBuilding.
  ///
  /// In en, this message translates to:
  /// **'Whole building'**
  String get scopeWholeBuilding;

  /// Picker chip for a resident with several apartments: everything they can see.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get scopeAllHomes;

  /// No description provided for @scopeAllRooms.
  ///
  /// In en, this message translates to:
  /// **'All rooms'**
  String get scopeAllRooms;

  /// No description provided for @scopePickUnit.
  ///
  /// In en, this message translates to:
  /// **'Choose the apartment'**
  String get scopePickUnit;

  /// No description provided for @scopePickRoom.
  ///
  /// In en, this message translates to:
  /// **'Choose the room'**
  String get scopePickRoom;

  /// No description provided for @checklistWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get checklistWaiting;

  /// No description provided for @checklistSkipped.
  ///
  /// In en, this message translates to:
  /// **'Offline, skipped'**
  String get checklistSkipped;

  /// No description provided for @noOwnSensors.
  ///
  /// In en, this message translates to:
  /// **'No sensors found in your apartment.'**
  String get noOwnSensors;

  /// No description provided for @statusOnline.
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get statusOnline;

  /// No description provided for @lastTestNoTime.
  ///
  /// In en, this message translates to:
  /// **'Last test: {result}'**
  String lastTestNoTime(String result);

  /// No description provided for @cmdErrHubOffline.
  ///
  /// In en, this message translates to:
  /// **'the hub is not connected to the sensors right now'**
  String get cmdErrHubOffline;

  /// No description provided for @lastOtherCommand.
  ///
  /// In en, this message translates to:
  /// **'{command}: {result} · {when}'**
  String lastOtherCommand(String command, String result, String when);

  /// No description provided for @lastOtherCommandNoTime.
  ///
  /// In en, this message translates to:
  /// **'{command}: {result}'**
  String lastOtherCommandNoTime(String command, String result);

  /// No description provided for @lastTestShort.
  ///
  /// In en, this message translates to:
  /// **'Test: {result} · {when}'**
  String lastTestShort(String result, String when);

  /// No description provided for @homeAllWell.
  ///
  /// In en, this message translates to:
  /// **'All is well'**
  String get homeAllWell;

  /// No description provided for @homeMonitored.
  ///
  /// In en, this message translates to:
  /// **'Your home is monitored'**
  String get homeMonitored;

  /// No description provided for @homeEvacuateLine.
  ///
  /// In en, this message translates to:
  /// **'Leave now by the stairs, not the lift.'**
  String get homeEvacuateLine;

  /// No description provided for @myRooms.
  ///
  /// In en, this message translates to:
  /// **'My rooms'**
  String get myRooms;

  /// No description provided for @buildingSection.
  ///
  /// In en, this message translates to:
  /// **'Building'**
  String get buildingSection;

  /// No description provided for @buildingNoIncidents.
  ///
  /// In en, this message translates to:
  /// **'Building: no active incidents'**
  String get buildingNoIncidents;

  /// No description provided for @buildingIncident.
  ///
  /// In en, this message translates to:
  /// **'Building: {hazard}'**
  String buildingIncident(String hazard);

  /// No description provided for @allSensors.
  ///
  /// In en, this message translates to:
  /// **'All sensors'**
  String get allSensors;

  /// No description provided for @showSensors.
  ///
  /// In en, this message translates to:
  /// **'Show sensors'**
  String get showSensors;

  /// No description provided for @hideSensors.
  ///
  /// In en, this message translates to:
  /// **'Hide sensors'**
  String get hideSensors;

  /// Hint on a collapsed home section header.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get expandSection;

  /// Hint on an expanded home section header.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get collapseSection;

  /// No description provided for @openRoom.
  ///
  /// In en, this message translates to:
  /// **'Open the room'**
  String get openRoom;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @themeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get themeAuto;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @themeHint.
  ///
  /// In en, this message translates to:
  /// **'Auto follows the phone\'s setting.'**
  String get themeHint;

  /// No description provided for @whereHome.
  ///
  /// In en, this message translates to:
  /// **'In your home: {room}'**
  String whereHome(String room);

  /// No description provided for @whereMyFloor.
  ///
  /// In en, this message translates to:
  /// **'On your floor: {unit}'**
  String whereMyFloor(String unit);

  /// No description provided for @whereMyFloorCommon.
  ///
  /// In en, this message translates to:
  /// **'On your floor: {area} (common area)'**
  String whereMyFloorCommon(String area);

  /// No description provided for @whereOtherFloor.
  ///
  /// In en, this message translates to:
  /// **'On another floor: {place}'**
  String whereOtherFloor(String place);

  /// No description provided for @whereCommonArea.
  ///
  /// In en, this message translates to:
  /// **'In a common area: {area}'**
  String whereCommonArea(String area);

  /// No description provided for @whereBuilding.
  ///
  /// In en, this message translates to:
  /// **'In the building: {place}'**
  String whereBuilding(String place);

  /// No description provided for @whereUnknown.
  ///
  /// In en, this message translates to:
  /// **'In the building (exact place not known yet)'**
  String get whereUnknown;

  /// The resident's own home on the alarm screen.
  ///
  /// In en, this message translates to:
  /// **'You: {home}'**
  String youAre(String home);

  /// No description provided for @whereNowQuestion.
  ///
  /// In en, this message translates to:
  /// **'Where are you now?'**
  String get whereNowQuestion;

  /// No description provided for @whereNowWhy.
  ///
  /// In en, this message translates to:
  /// **'Your answer goes to the building manager.'**
  String get whereNowWhy;

  /// No description provided for @whereNowHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get whereNowHome;

  /// No description provided for @whereNowBuilding.
  ///
  /// In en, this message translates to:
  /// **'Elsewhere in the building'**
  String get whereNowBuilding;

  /// No description provided for @whereNowOutside.
  ///
  /// In en, this message translates to:
  /// **'Outside'**
  String get whereNowOutside;

  /// No description provided for @whereYouSaid.
  ///
  /// In en, this message translates to:
  /// **'You are: {where}'**
  String whereYouSaid(String where);

  /// No description provided for @whereSent.
  ///
  /// In en, this message translates to:
  /// **'Sent: {where}'**
  String whereSent(String where);

  /// No description provided for @whereNotSent.
  ///
  /// In en, this message translates to:
  /// **'Not sent: no connection. Your answer is saved on the phone; tap it again to resend.'**
  String get whereNotSent;

  /// No description provided for @adviceLeaveHomeNow.
  ///
  /// In en, this message translates to:
  /// **'The danger is in your home. Leave now, close the door behind you and take the stairs.'**
  String get adviceLeaveHomeNow;

  /// No description provided for @adviceLeaveHome.
  ///
  /// In en, this message translates to:
  /// **'Take your phone and keys, close the door behind you and leave by the route below.'**
  String get adviceLeaveHome;

  /// No description provided for @adviceGetReady.
  ///
  /// In en, this message translates to:
  /// **'Get ready to leave: phone, keys, shoes. Leave right away if you are told to or if the danger comes closer.'**
  String get adviceGetReady;

  /// No description provided for @adviceLeaveBuilding.
  ///
  /// In en, this message translates to:
  /// **'Leave by the nearest stairs. Don\'t go back for your things and don\'t use the lift.'**
  String get adviceLeaveBuilding;

  /// No description provided for @adviceStayOut.
  ///
  /// In en, this message translates to:
  /// **'Stay outside and go to the assembly point: {point}. Don\'t go back in until you\'re told it\'s safe.'**
  String adviceStayOut(String point);

  /// No description provided for @adviceStayOutNoPoint.
  ///
  /// In en, this message translates to:
  /// **'Stay outside, away from the building. Don\'t go back in until you\'re told it\'s safe.'**
  String get adviceStayOutNoPoint;

  /// No description provided for @dangerPlanTitle.
  ///
  /// In en, this message translates to:
  /// **'Where the danger is'**
  String get dangerPlanTitle;

  /// No description provided for @planCaption.
  ///
  /// In en, this message translates to:
  /// **'{floor} · sketch, not to scale'**
  String planCaption(String floor);

  /// No description provided for @planCaptionNoFloor.
  ///
  /// In en, this message translates to:
  /// **'Sketch, not to scale'**
  String get planCaptionNoFloor;

  /// No description provided for @planYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get planYou;

  /// No description provided for @planDanger.
  ///
  /// In en, this message translates to:
  /// **'Danger'**
  String get planDanger;

  /// No description provided for @planExit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get planExit;

  /// No description provided for @affectedRoomsTitle.
  ///
  /// In en, this message translates to:
  /// **'Affected rooms'**
  String get affectedRoomsTitle;

  /// No description provided for @roomTagSource.
  ///
  /// In en, this message translates to:
  /// **'where it started'**
  String get roomTagSource;

  /// No description provided for @roomTagYours.
  ///
  /// In en, this message translates to:
  /// **'your home'**
  String get roomTagYours;
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

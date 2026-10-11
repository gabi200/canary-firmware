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
  String get language => 'Language';

  @override
  String get languageHint => 'Also used for the sensor analysis from the hub.';

  @override
  String get settings => 'Settings';

  @override
  String get live => 'Live';

  @override
  String get reconnecting => 'Reconnecting…';

  @override
  String get allClear => 'All clear';

  @override
  String get evacuateNow => 'EVACUATE NOW';

  @override
  String get onboardingTagline => 'Building safety for residents';

  @override
  String get username => 'Username';

  @override
  String get buildingId => 'Building ID';

  @override
  String get linkMyUnit => 'Link my unit';

  @override
  String serverAddress(String url) {
    return 'Server: $url';
  }

  @override
  String loginFailed(String reason) {
    return 'Login failed: $reason';
  }

  @override
  String get serverUnreachable =>
      'Can\'t reach the server. Check your connection.';

  @override
  String serverError(int code) {
    return 'Server error ($code)';
  }

  @override
  String get openEvacuationGuidance => 'Open evacuation guidance';

  @override
  String get activeIncidents => 'Active incidents';

  @override
  String get noActiveIncidents => 'No active incidents';

  @override
  String get yourBuildingMonitored => 'Your building is being monitored.';

  @override
  String get buildingMonitored => 'Building is being monitored.';

  @override
  String get noActiveHazard =>
      'No active hazard. You will be alerted immediately if anything is detected.';

  @override
  String get noActiveHazardInBuilding => 'No active hazard in this building.';

  @override
  String checkInsQueued(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString check-ins queued',
      one: '1 check-in queued',
    );
    return '$_temp0';
  }

  @override
  String get hazardGasLeak => 'Gas leak';

  @override
  String get hazardCarbonMonoxide => 'Carbon monoxide';

  @override
  String get hazardWaterLeak => 'Water leak';

  @override
  String get hazardSmoke => 'Smoke / particulates';

  @override
  String get stateNormal => 'normal';

  @override
  String get stateDetection => 'detection';

  @override
  String get stateVerification => 'verification';

  @override
  String get stateAlarm => 'alarm';

  @override
  String get stateEscalation => 'escalation';

  @override
  String get stateEvacuation => 'evacuation';

  @override
  String get stateResolution => 'resolved';

  @override
  String get stateFalseAlarm => 'false alarm';

  @override
  String get levelOk => 'ok';

  @override
  String get levelAttention => 'attention';

  @override
  String get levelDanger => 'danger';

  @override
  String get levelUnknown => 'unknown';

  @override
  String get statusOffline => 'offline';

  @override
  String get statusNoData => 'no data';

  @override
  String get occupied => 'occupied';

  @override
  String get empty => 'empty';

  @override
  String get homeStatus => 'Home status';

  @override
  String get buildingSensors => 'Building sensors';

  @override
  String get statusNeedsAttention => 'Needs attention';

  @override
  String get statusDanger => 'Danger';

  @override
  String get statusUnknown => 'Status unknown';

  @override
  String sensorsOnline(int online, int total) {
    final intl.NumberFormat onlineNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String onlineString = onlineNumberFormat.format(online);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$onlineString of $totalString sensors online',
      one: '$onlineString of 1 sensor online',
    );
    return '$_temp0';
  }

  @override
  String activeIncidentCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString active incidents',
      one: '1 active incident',
    );
    return '$_temp0';
  }

  @override
  String get noRecentData => 'No recent data';

  @override
  String get sensorOffline => 'Offline';

  @override
  String lastSeen(String status, String when) {
    return '$status · last seen $when';
  }

  @override
  String get kindAir => 'Air sensor';

  @override
  String get kindWater => 'Water sensor';

  @override
  String get kindSensor => 'Sensor';

  @override
  String get whatToDo => 'What to do';

  @override
  String get indicatorAirQuality => 'Air quality';

  @override
  String get indicatorCo => 'Carbon monoxide';

  @override
  String get indicatorGas => 'Gas';

  @override
  String get indicatorComfort => 'Comfort';

  @override
  String get indicatorOccupancy => 'Occupancy';

  @override
  String get indicatorLeak => 'Water leak';

  @override
  String get indicatorValve => 'Water valve';

  @override
  String get trendRising => 'rising';

  @override
  String get trendFalling => 'falling';

  @override
  String get trendStable => 'stable';

  @override
  String get loadingSensorStatus => 'Loading sensor status…';

  @override
  String get sensorStatusUnavailable => 'Sensor status unavailable';

  @override
  String get hubUnreachable =>
      'Can\'t reach the hub right now. Pull down to retry.';

  @override
  String get noSensorsConnected => 'No sensors connected';

  @override
  String get noSensorsHint =>
      'Sensor status appears here once a Canary device joins the hub.';

  @override
  String get refreshFailed => 'Couldn\'t refresh sensor status';

  @override
  String refreshFailedShowingFrom(String time) {
    return 'Couldn\'t refresh · showing status from $time';
  }

  @override
  String get timeJustNow => 'just now';

  @override
  String minutesAgo(int minutes) {
    final intl.NumberFormat minutesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String minutesString = minutesNumberFormat.format(minutes);

    return '$minutesString min ago';
  }

  @override
  String hoursAgo(int hours) {
    final intl.NumberFormat hoursNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String hoursString = hoursNumberFormat.format(hours);

    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hoursString h ago',
    );
    return '$_temp0';
  }

  @override
  String get offlineShowingSavedRoute => 'Offline · showing saved route';

  @override
  String get minimize => 'Minimize';

  @override
  String get dontGas => 'Don\'t use the lift, light switches, or open flames.';

  @override
  String get dontCo => 'Don\'t stay inside. Get to fresh air now.';

  @override
  String get dontSmoke => 'Stay low under smoke. Don\'t use the lift.';

  @override
  String get dontWaterLeak =>
      'Don\'t touch electrical devices or switches near water.';

  @override
  String get dontDefault => 'Don\'t use the lift.';

  @override
  String get routeCrossesHazard =>
      'This route passes near the hazard. Use another marked exit if you can, and call 112.';

  @override
  String get routeUnchecked =>
      'We couldn\'t check this route against the hazard. Follow the marked exits, stay away from the hazard, and call 112 if unsure.';

  @override
  String get evacuationRoute => 'Evacuation route';

  @override
  String get useNearestExit => 'Use the nearest marked exit';

  @override
  String get useNearestExitDetail =>
      'Take the stairs (not the lift) to the outdoor assembly point. Do not return inside.';

  @override
  String checkInSent(String status) {
    return 'Check-in sent: $status';
  }

  @override
  String get checkInQueued =>
      'Offline — check-in queued, will send automatically';

  @override
  String get dial112 => 'Dial 112 on your phone';

  @override
  String checkedIn(String status) {
    return 'Checked in: $status';
  }

  @override
  String get change => 'Change';

  @override
  String get imOutAndSafe => 'I\'m out and safe';

  @override
  String get iNeedHelp => 'I need help';

  @override
  String get call112 => 'Call 112';

  @override
  String get imSafeStillInside => 'I\'m safe but still inside';

  @override
  String get hazardCleared => 'The hazard has cleared.';

  @override
  String get returnAction => 'Return';

  @override
  String get startHere => 'Start here';

  @override
  String avoidZone(String zone) {
    return 'Avoid: $zone';
  }

  @override
  String routeStep(int step, int total, String label) {
    return 'Step $step of $total: $label.';
  }

  @override
  String get evacuationOrdered => 'Evacuation ordered';

  @override
  String get incidentResolved => 'Incident resolved';

  @override
  String get incidentDismissed => 'Incident dismissed';

  @override
  String actionFailed(String reason) {
    return 'Action failed: $reason';
  }

  @override
  String get victimAccounting => 'Victim accounting';

  @override
  String get couldNotLoadAccounting => 'Could not load accounting';

  @override
  String get metricOccupants => 'Occupants';

  @override
  String get metricAccounted => 'Accounted';

  @override
  String get metricUnaccounted => 'Unaccounted';

  @override
  String get metricNeedHelp => 'Need help';

  @override
  String get residentAccountability => 'Resident accountability';

  @override
  String get couldNotLoadRoster => 'Could not load roster';

  @override
  String get noResidentsRegistered => 'No residents registered.';

  @override
  String get rosterNeedsHelp => 'NEEDS HELP';

  @override
  String get rosterSafeOutside => 'Safe — out';

  @override
  String get rosterSafeInside => 'Safe — in';

  @override
  String get rosterNoResponse => 'No response';

  @override
  String get rosterAwaiting => 'Awaiting';

  @override
  String get orderEvacuation => 'Order evacuation';

  @override
  String get resolve => 'Resolve';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get account => 'My account';

  @override
  String get roleResident => 'Resident';

  @override
  String get roleManager => 'Building manager';

  @override
  String get roleDispatcher => 'Dispatcher';

  @override
  String get roleAdmin => 'System admin';

  @override
  String get presenceContribution => 'Presence contribution';

  @override
  String get sharePresence => 'Share my presence during incidents';

  @override
  String get sharePresenceDetail =>
      'Lets responders better account for who is inside. Anonymous; used only during an active incident.';

  @override
  String get about => 'About';

  @override
  String get aboutAppName => 'Canary resident';

  @override
  String aboutDisclaimer(String version) {
    return 'v$version — advisory safety app. Not a substitute for certified alarms.';
  }

  @override
  String get server => 'Server';

  @override
  String get signOut => 'Sign out';

  @override
  String get notificationChannelName => 'Emergency alerts';

  @override
  String get notificationChannelDescription =>
      'Critical building safety alarms (gas, CO, evacuation).';

  @override
  String notifAlarmTitle(String hazard) {
    return '$hazard ALARM';
  }

  @override
  String notifAlarmBody(String hazard) {
    return '$hazard detected. Prepare to evacuate. Follow guidance.';
  }

  @override
  String get notifAlarmBodyWaterLeak =>
      'Water leak detected. If a shut-off valve is fitted, it closed automatically. Avoid the area and check the unit.';

  @override
  String get notifAlarmBodySmoke =>
      'Smoke or heavy particulates detected. Check for smoke or fire and ventilate if safe. If there is a fire, leave and call 112.';

  @override
  String notifEvacuateTitle(String hazard) {
    return 'EVACUATE NOW — $hazard';
  }

  @override
  String get notifEvacuateBody =>
      'Evacuate via the safe route to the assembly point. Check in when safe.';

  @override
  String notifEscalatedTitle(String hazard) {
    return '$hazard escalated';
  }

  @override
  String get notifEscalatedBody =>
      'Incident escalated to monitoring/emergency partners.';

  @override
  String notifAlertTitle(String hazard) {
    return '$hazard alert';
  }

  @override
  String get notifOpenForGuidance => 'Open Canary for guidance.';

  @override
  String get pushFallbackTitle => 'Canary alert';

  @override
  String get measurements => 'Measurements';

  @override
  String get rangeHourShort => '1h';

  @override
  String get range24hShort => '24h';

  @override
  String get range7dShort => '7d';

  @override
  String get rangeHour => 'Last hour';

  @override
  String get range24h => '24 hours';

  @override
  String get range7d => '7 days';

  @override
  String get inLastHour => 'in the last hour';

  @override
  String get inLast24h => 'in the last 24 hours';

  @override
  String get inLast7d => 'in the last 7 days';

  @override
  String get tileTemperature => 'Temperature';

  @override
  String get tileHumidity => 'Humidity';

  @override
  String get tileFineParticles => 'Fine particles (PM2.5)';

  @override
  String get tileParticles => 'Particles (PM10)';

  @override
  String get tileGas => 'Gas level';

  @override
  String get tileLeak => 'Leak';

  @override
  String get tileValve => 'Valve';

  @override
  String get chipAir => 'Air';

  @override
  String get chipWater => 'Water';

  @override
  String get noLeaks => 'No leaks';

  @override
  String get gasOfWarning => 'of warning level';

  @override
  String get verdictGood => 'Good';

  @override
  String get verdictModerate => 'Moderate';

  @override
  String get verdictPoor => 'Poor';

  @override
  String get verdictDanger => 'Danger';

  @override
  String get verdictSafe => 'Safe';

  @override
  String get verdictElevated => 'Elevated';

  @override
  String get verdictNormal => 'Normal';

  @override
  String get verdictCool => 'Cool';

  @override
  String get verdictComfortable => 'Comfortable';

  @override
  String get verdictWarm => 'Warm';

  @override
  String get verdictDryAir => 'Dry air';

  @override
  String get verdictHumidityOk => 'Normal';

  @override
  String get verdictHumid => 'Humid';

  @override
  String get verdictDry => 'Dry';

  @override
  String get verdictLeak => 'Leak';

  @override
  String get approx => 'Approx.';

  @override
  String get warmingUp => 'Sensor warming up';

  @override
  String get warmingUpShort => 'Warming up';

  @override
  String noReadings(String range) {
    return 'No readings $range.';
  }

  @override
  String get historyFailed => 'Couldn\'t load the measurements.';

  @override
  String get retry => 'Retry';

  @override
  String lastLeak(String time) {
    return 'Last leak: $time';
  }

  @override
  String noLeakIn(String range) {
    return 'No leak $range';
  }

  @override
  String get approxNote =>
      '≈ Approx.: measured inside the sensor, so it may differ slightly from the room.';

  @override
  String get analysisDetails => 'Analysis details';

  @override
  String tileSemantics(String label, String value, String word, String min,
      String max, String range) {
    return '$label: $value, $word. Between $min and $max $range.';
  }

  @override
  String spokenTemperature(String value) {
    return 'about $value degrees';
  }

  @override
  String spokenHumidity(String value) {
    return 'about $value percent';
  }

  @override
  String spokenParticles(String value) {
    return '$value micrograms per cubic metre';
  }

  @override
  String spokenCo(String value) {
    return '$value parts per million';
  }

  @override
  String spokenGas(String value) {
    return '$value percent of warning level';
  }

  @override
  String get careProfileTitle => 'Emergency profile';

  @override
  String get careProfileSettingsSubtitle =>
      'Help first for anyone at home who can\'t get out alone';

  @override
  String get careEmptyBody =>
      'If someone at home can\'t get out alone in an emergency (a grandparent, a small child), add them here. The dispatcher and the building manager see this only during an emergency, so that person is helped first.';

  @override
  String get careAddPerson => 'Add person';

  @override
  String get careSelfBadge => 'Me';

  @override
  String get careForMe => 'For me';

  @override
  String get careForOther => 'Someone else at home';

  @override
  String get careName => 'Name';

  @override
  String get careNameRequired => 'Enter a name';

  @override
  String get careUnit => 'Apartment';

  @override
  String get careNeedsLabel => 'What help is needed?';

  @override
  String get careNote => 'Note (optional)';

  @override
  String get careNoteHint =>
      'E.g. uses a walking frame, sleeps in the back room';

  @override
  String get careConsent =>
      'I agree that this health information may be seen by the dispatcher and the building manager, only during an emergency, so that the person who needs help is helped first. I can delete it at any time. Every access is logged.';

  @override
  String get careSaveHint =>
      'To save: tick the agreement and choose a need or write a note.';

  @override
  String get careSave => 'Save';

  @override
  String get careNewTitle => 'New profile';

  @override
  String get careEditTitle => 'Edit profile';

  @override
  String get careDelete => 'Delete profile';

  @override
  String get careDeleteConfirmTitle => 'Delete the profile?';

  @override
  String get careDeleteConfirmBody => 'The information is deleted permanently.';

  @override
  String get cancel => 'Cancel';

  @override
  String get delete => 'Delete';

  @override
  String get careSaved => 'Profile saved';

  @override
  String get careDeleted => 'Profile deleted';

  @override
  String get careNotActive => 'This feature isn\'t active on this hub.';

  @override
  String get careSelfExists => 'You already have a profile for yourself.';

  @override
  String get careUnitNotYours =>
      'This apartment isn\'t linked to your account.';

  @override
  String get careInvalid =>
      'Check the details: choose at least one need or write a note.';

  @override
  String get careNoUnit => 'We couldn\'t find your apartment. Try again later.';

  @override
  String get careLoadFailed => 'Couldn\'t load the emergency profiles.';

  @override
  String get carePrivacyNote =>
      'Stored only on the building\'s hub, not on this phone. Shown only during an emergency. You can delete it at any time.';

  @override
  String get needReducedMobility => 'Reduced mobility';

  @override
  String get needWheelchair => 'Wheelchair user';

  @override
  String get needBedridden => 'Bedridden';

  @override
  String get needHearingImpaired => 'Can\'t hear the alarm';

  @override
  String get needVisuallyImpaired => 'Blind or low vision';

  @override
  String get needMedicalDevice => 'Oxygen or medical equipment';

  @override
  String get needYoungChild => 'Young child';

  @override
  String get needPet => 'Pet';

  @override
  String get careHintTitle => 'Someone at home needs help getting out?';

  @override
  String get careHintAction => 'Add an emergency profile';

  @override
  String get householdTitle => 'Who else is at home?';

  @override
  String get householdOut => 'Outside';

  @override
  String get householdInside => 'Still inside';

  @override
  String get householdNeedsHelp => 'Needs help';

  @override
  String householdSent(String status) {
    return 'Sent: $status';
  }

  @override
  String get householdSending => 'Sending…';

  @override
  String get householdFailed => 'Not sent — no connection.';

  @override
  String get householdLoadFailed => 'Couldn\'t load your apartment.';

  @override
  String householdPersonSemantics(String name) {
    return '$name, where is this person now?';
  }

  @override
  String get accountName => 'Name';

  @override
  String get accountPhone => 'Phone';

  @override
  String get accountPhoneHint =>
      'The dispatcher calls you on this number in an emergency';

  @override
  String get accountEmail => 'Email';

  @override
  String get accountRole => 'Role';

  @override
  String get accountSaved => 'Account saved';

  @override
  String get accountNotAvailable =>
      'Editing your account isn\'t available on this hub yet.';

  @override
  String get accountLoadFailed => 'Couldn\'t load your account.';

  @override
  String get accountPhoneInvalid =>
      'Enter a valid phone number, e.g. 0722 123 456';

  @override
  String get accountEmailInvalid => 'Enter a valid email address';

  @override
  String get accountReadOnlyNote =>
      'Username, role and apartment are set by the building manager.';

  @override
  String get accountEditHint => 'Edit your name, phone and email';

  @override
  String get chipCoHigh => 'High CO';

  @override
  String get chipCoDanger => 'Dangerous CO';

  @override
  String get chipGasHigh => 'High gas level';

  @override
  String get chipGasDanger => 'Dangerous gas level';

  @override
  String get verifyingTitle => 'Checking a possible problem';

  @override
  String get verifyingCalm =>
      'No need to leave yet. We\'ll tell you right away if you should.';

  @override
  String get attentionBody => 'No active hazard. See the room marked below.';

  @override
  String get dangerBody => 'Check the room marked below and follow the advice.';

  @override
  String get statusUnknownBody =>
      'The sensors haven\'t reported yet. Their status appears here as soon as they do.';

  @override
  String get healthImportButton => 'Import from Health (Apple)';

  @override
  String get healthImporting => 'Reading Health data…';

  @override
  String get healthFoundTitle => 'Found in Health:';

  @override
  String get healthNothingFound =>
      'No relevant data found. You can fill this in yourself.';

  @override
  String get healthAccessNote =>
      'iOS doesn\'t tell apps whether access was refused. If you didn\'t allow it, turn it on in Settings > Health > Data Access & Devices.';

  @override
  String get healthUnavailable =>
      'Health data isn\'t available on this device.';

  @override
  String get healthReadFailed =>
      'Couldn\'t read data from Health. You can fill this in yourself.';

  @override
  String get healthFromProfile => 'from the Health profile';

  @override
  String healthFromSteadiness(String value) {
    return 'walking steadiness $value %';
  }

  @override
  String healthFromAudiogram(String value) {
    return 'audiogram: $value dB in the better ear';
  }

  @override
  String get healthAdd => 'Add';

  @override
  String get healthPrivacy =>
      'Read only on this phone. Nothing is saved until you save the profile with your consent.';

  @override
  String healthSuggestionSemantics(String need, String source) {
    return '$need, $source. Add to the profile?';
  }

  @override
  String get range6hShort => '6h';

  @override
  String get range6h => '6 hours';

  @override
  String get inLast6h => 'in the last 6 hours';

  @override
  String chartThresholdWarn(String value) {
    return 'Warning level $value';
  }

  @override
  String chartThresholdDanger(String value) {
    return 'Danger level $value';
  }

  @override
  String get chartNoData => 'no data';

  @override
  String get chartNow => 'Now';

  @override
  String get chartMin => 'Min';

  @override
  String get chartMean => 'Average';

  @override
  String get chartMax => 'Max';

  @override
  String get chartWhatMeans => 'What does it mean?';

  @override
  String get chartHint => 'Touch and drag on the chart to see the exact value.';

  @override
  String chartAt(String time, String value) {
    return 'At $time: $value';
  }

  @override
  String get chartPrevMetric => 'Previous measurement';

  @override
  String get chartNextMetric => 'Next measurement';

  @override
  String get explainTemperature =>
      'Measured inside the sensor, so it is approximate and may read a little warmer than the room.';

  @override
  String get explainHumidity =>
      'Measured inside the sensor, approximate. Comfortable indoors: about 30–60 %.';

  @override
  String explainPm25(String warn) {
    return 'Fine dust from smoke, cooking or outside air. Lower is better; the sensor warns from $warn.';
  }

  @override
  String explainPm10(String warn) {
    return 'Coarser dust and pollen. The sensor warns from $warn.';
  }

  @override
  String explainCo(String warn) {
    return 'Carbon monoxide is a gas with no smell. The sensor alerts you from $warn.';
  }

  @override
  String get explainGas =>
      '% of the sensor\'s warning level, not a concentration. Above 100 % the sensor raises an alarm.';

  @override
  String get explainLeak =>
      'Dry or wet, as the water sensor on the floor reports it.';

  @override
  String get homeViewList => 'List';

  @override
  String get homeViewSketch => 'Sketch';

  @override
  String get sketchCommonArea => 'common area';

  @override
  String get sketchAvoid => 'Avoid';

  @override
  String sensorCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString sensors',
      one: '1 sensor',
    );
    return '$_temp0';
  }

  @override
  String get sketchNoPositions =>
      'Room positions aren\'t known yet, so rooms are shown in order.';

  @override
  String get sketchHint =>
      'A sketch of your rooms, not to scale. Tap a room for its sensors.';

  @override
  String get householdSettingsTitle => 'My apartment';

  @override
  String get householdSettingsSubtitle => 'Who lives here, and invites';

  @override
  String get householdMembers => 'People with an account';

  @override
  String householdMemberSince(String date) {
    return 'since $date';
  }

  @override
  String get householdPendingInvites => 'Pending invites';

  @override
  String householdExpires(String when) {
    return 'Expires: $when';
  }

  @override
  String householdInviteFor(String name) {
    return 'for $name';
  }

  @override
  String get householdRevoke => 'Cancel invite';

  @override
  String get householdInviteSomeone => 'Invite someone with an account';

  @override
  String get householdLeave => 'Leave the apartment';

  @override
  String householdLeaveTitle(String unit) {
    return 'Leave $unit?';
  }

  @override
  String get householdLeaveBody =>
      'You will no longer see this apartment\'s sensors or get its alerts. The emergency profiles you created for it are deleted.';

  @override
  String get householdLeaveConfirm => 'Leave';

  @override
  String get householdLeft => 'You left the apartment';

  @override
  String get householdEmpty => 'No apartment is linked to your account.';

  @override
  String get householdTooManyInvites =>
      'There are already 5 pending invites. Cancel one first.';

  @override
  String get inviteSheetTitle => 'Invite link';

  @override
  String get inviteCopy => 'Copy link';

  @override
  String get inviteCopied => 'Link copied';

  @override
  String get inviteSms => 'Send by SMS';

  @override
  String get inviteEmail => 'Send by email';

  @override
  String inviteExpiryHours(int hours) {
    final intl.NumberFormat hoursNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String hoursString = hoursNumberFormat.format(hours);

    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Expires in $hoursString hours, single use.',
      one: 'Expires in 1 hour, single use.',
    );
    return '$_temp0';
  }

  @override
  String inviteMessage(String unit, String url) {
    return 'Join our apartment ($unit) in Canary: $url';
  }

  @override
  String get inviteEmailSubject => 'Invitation to Canary';

  @override
  String get careInviteMember => 'Has their own account? Send them an invite';

  @override
  String get inviteCodeEntry => 'I have an invite code';

  @override
  String get inviteCodeLabel => 'Invite code';

  @override
  String get inviteCodeHint => 'Paste the code or the whole link';

  @override
  String get inviteCodeInvalid => 'That doesn\'t look like an invite code.';

  @override
  String get inviteContinue => 'Continue';

  @override
  String get inviteTitle => 'Invitation';

  @override
  String inviteFrom(String inviter) {
    return '$inviter invites you to join';
  }

  @override
  String get inviteBuilding => 'Building';

  @override
  String get inviteFloor => 'Floor';

  @override
  String inviteCareOffer(String inviter, String name) {
    return '$inviter created an emergency profile for you ($name). Do you want to take it over?';
  }

  @override
  String get inviteTakeOver => 'Yes, take over this profile';

  @override
  String get inviteAccept => 'Accept';

  @override
  String get inviteDecline => 'Decline';

  @override
  String inviteAccepted(String unit) {
    return 'You joined $unit';
  }

  @override
  String get inviteInvalid =>
      'This invite is no longer valid (expired, used or mistyped).';

  @override
  String get inviteStaff => 'Only residents can join an apartment.';

  @override
  String get inviteConflict =>
      'You can\'t accept your own invite, or you already have an emergency profile for yourself.';

  @override
  String get inviteNeedsConsent =>
      'Tick the agreement to take over the profile.';

  @override
  String get inviteTooMany => 'Too many attempts. Try again later.';

  @override
  String get inviteLoginFirst => 'Sign in to accept the invitation.';

  @override
  String get inviteLoading => 'Loading the invitation…';

  @override
  String get testSectionTitle => 'Test the sensor';

  @override
  String get testAlarmButton => 'Test the alarm (4 s)';

  @override
  String get testAlarmHint => 'The sensor will beep and flash for 4 seconds.';

  @override
  String get silenceAlarmButton => 'Silence the alarm';

  @override
  String get closeValveButton => 'Close the valve';

  @override
  String get openValveButton => 'Open the valve';

  @override
  String get closeValveConfirmTitle => 'Close the valve?';

  @override
  String get closeValveConfirmBody =>
      'The valve will shut off the water in the apartment until you open it again.';

  @override
  String get commonAreaTestNote =>
      'Only the building manager can test sensors in common areas.';

  @override
  String get testOfflineNote =>
      'The sensor is offline. You can test it once it reconnects.';

  @override
  String get runSent => 'Sent…';

  @override
  String get runAccepted => 'Done';

  @override
  String runRejected(String reason) {
    return 'Refused: $reason';
  }

  @override
  String get runRejectedPlain => 'Refused';

  @override
  String get runTimeout => 'No answer';

  @override
  String get runTimeoutHint => 'The sensor did not answer within 15 seconds.';

  @override
  String runFailed(String reason) {
    return 'Not sent: $reason';
  }

  @override
  String get commandTest => 'Alarm test';

  @override
  String get commandSilence => 'Silence alarm';

  @override
  String get commandOpen => 'Open valve';

  @override
  String get commandClose => 'Close valve';

  @override
  String get cmdErrOffline => 'the sensor is offline';

  @override
  String get cmdErrTooSoon => 'wait a few seconds between commands';

  @override
  String get cmdErrNotYours => 'this sensor is not in your apartment';

  @override
  String get cmdErrInvalid => 'this sensor does not take that command';

  @override
  String get cmdErrForbidden => 'your account cannot send commands';

  @override
  String get detailSelfTest => 'self-test started';

  @override
  String get detailSilenced => 'alarm silenced';

  @override
  String get detailSelfTestBusy => 'a self-test is already running';

  @override
  String get detailAlarmInactive => 'no active alarm';

  @override
  String get detailOpen => 'valve open';

  @override
  String get detailClosed => 'valve closed';

  @override
  String get detailBusy => 'the sensor is busy with another command';

  @override
  String get detailInvalidCommand => 'the sensor does not know this command';

  @override
  String get detailSensorWet => 'the sensor still detects water';

  @override
  String get detailSensorUninitialized => 'the sensor is still starting up';

  @override
  String get detailOtaActive => 'the sensor is updating';

  @override
  String get detailCommandRejected => 'the sensor refused the command';

  @override
  String get detailPersistenceFailed => 'the valve state could not be saved';

  @override
  String lastTest(String result, String when) {
    return 'Last test: $result · $when';
  }

  @override
  String get lastTestNone => 'Not tested yet';

  @override
  String get lastTestAccepted => 'passed';

  @override
  String get lastTestRejected => 'refused';

  @override
  String get lastTestTimeout => 'no answer';

  @override
  String get lastTestSent => 'in progress';

  @override
  String get testMySensors => 'Test my sensors';

  @override
  String get testMySensorsSubtitle => 'Make each sensor beep for a moment';

  @override
  String get testBuildingSensors => 'Test sensors';

  @override
  String get testBuildingSensorsSubtitle =>
      'Every sensor in the building, by room';

  @override
  String get testAllAlarms => 'Test all alarms';

  @override
  String get testAllHint =>
      'Your apartment\'s air sensors beep one after another, 4 seconds each. Water valves are never closed.';

  @override
  String testAllRunning(int done, int total) {
    final intl.NumberFormat doneNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String doneString = doneNumberFormat.format(done);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Testing $doneString of $totalString…';
  }

  @override
  String testAllDone(int passed, int total) {
    final intl.NumberFormat passedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String passedString = passedNumberFormat.format(passed);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Done: $passedString of $totalString passed';
  }

  @override
  String get testAllNoAir => 'None of your air sensors is online right now.';

  @override
  String get testAllNoAirHere =>
      'None of the air sensors here is online right now.';

  @override
  String testAllAlarmsIn(String scope) {
    return 'Test all alarms · $scope';
  }

  @override
  String get testAllPickUnit =>
      'Pick an apartment above to test all its alarms in one go.';

  @override
  String get scopeWholeBuilding => 'Whole building';

  @override
  String get scopeAllHomes => 'All';

  @override
  String get scopeAllRooms => 'All rooms';

  @override
  String get scopePickUnit => 'Choose the apartment';

  @override
  String get scopePickRoom => 'Choose the room';

  @override
  String get checklistWaiting => 'Waiting';

  @override
  String get checklistSkipped => 'Offline, skipped';

  @override
  String get noOwnSensors => 'No sensors found in your apartment.';

  @override
  String get statusOnline => 'online';

  @override
  String lastTestNoTime(String result) {
    return 'Last test: $result';
  }

  @override
  String get cmdErrHubOffline =>
      'the hub is not connected to the sensors right now';

  @override
  String lastOtherCommand(String command, String result, String when) {
    return '$command: $result · $when';
  }

  @override
  String lastOtherCommandNoTime(String command, String result) {
    return '$command: $result';
  }

  @override
  String lastTestShort(String result, String when) {
    return 'Test: $result · $when';
  }

  @override
  String get homeAllWell => 'All is well';

  @override
  String get homeMonitored => 'Your home is monitored';

  @override
  String get homeEvacuateLine => 'Leave now by the stairs, not the lift.';

  @override
  String get myRooms => 'My rooms';

  @override
  String get buildingSection => 'Building';

  @override
  String get buildingNoIncidents => 'Building: no active incidents';

  @override
  String buildingIncident(String hazard) {
    return 'Building: $hazard';
  }

  @override
  String get allSensors => 'All sensors';

  @override
  String get showSensors => 'Show sensors';

  @override
  String get hideSensors => 'Hide sensors';

  @override
  String get expandSection => 'Show';

  @override
  String get collapseSection => 'Hide';

  @override
  String get openRoom => 'Open the room';

  @override
  String get appearance => 'Appearance';

  @override
  String get themeAuto => 'Auto';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeHint => 'Auto follows the phone\'s setting.';

  @override
  String whereHome(String room) {
    return 'In your home: $room';
  }

  @override
  String whereMyFloor(String unit) {
    return 'On your floor: $unit';
  }

  @override
  String whereMyFloorCommon(String area) {
    return 'On your floor: $area (common area)';
  }

  @override
  String whereOtherFloor(String place) {
    return 'On another floor: $place';
  }

  @override
  String whereCommonArea(String area) {
    return 'In a common area: $area';
  }

  @override
  String whereBuilding(String place) {
    return 'In the building: $place';
  }

  @override
  String get whereUnknown => 'In the building (exact place not known yet)';

  @override
  String youAre(String home) {
    return 'You: $home';
  }

  @override
  String get whereNowQuestion => 'Where are you now?';

  @override
  String get whereNowWhy => 'Your answer goes to the building manager.';

  @override
  String get whereNowHome => 'Home';

  @override
  String get whereNowBuilding => 'Elsewhere in the building';

  @override
  String get whereNowOutside => 'Outside';

  @override
  String whereYouSaid(String where) {
    return 'You are: $where';
  }

  @override
  String whereSent(String where) {
    return 'Sent: $where';
  }

  @override
  String get whereNotSent =>
      'Not sent: no connection. Your answer is saved on the phone; tap it again to resend.';

  @override
  String get adviceLeaveHomeNow =>
      'The danger is in your home. Leave now, close the door behind you and take the stairs.';

  @override
  String get adviceLeaveHome =>
      'Take your phone and keys, close the door behind you and leave by the route below.';

  @override
  String get adviceGetReady =>
      'Get ready to leave: phone, keys, shoes. Leave right away if you are told to or if the danger comes closer.';

  @override
  String get adviceLeaveBuilding =>
      'Leave by the nearest stairs. Don\'t go back for your things and don\'t use the lift.';

  @override
  String adviceStayOut(String point) {
    return 'Stay outside and go to the assembly point: $point. Don\'t go back in until you\'re told it\'s safe.';
  }

  @override
  String get adviceStayOutNoPoint =>
      'Stay outside, away from the building. Don\'t go back in until you\'re told it\'s safe.';

  @override
  String get dangerPlanTitle => 'Where the danger is';

  @override
  String planCaption(String floor) {
    return '$floor · sketch, not to scale';
  }

  @override
  String get planCaptionNoFloor => 'Sketch, not to scale';

  @override
  String get planYou => 'You';

  @override
  String get planDanger => 'Danger';

  @override
  String get planExit => 'Exit';

  @override
  String get affectedRoomsTitle => 'Affected rooms';

  @override
  String get roomTagSource => 'where it started';

  @override
  String get roomTagYours => 'your home';
}

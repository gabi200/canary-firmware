// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Romanian Moldavian Moldovan (`ro`).
class AppLocalizationsRo extends AppLocalizations {
  AppLocalizationsRo([String locale = 'ro']) : super(locale);

  @override
  String get appTitle => 'Canary';

  @override
  String get language => 'Limbă';

  @override
  String get languageHint =>
      'Folosită și pentru analiza senzorilor primită de la hub.';

  @override
  String get settings => 'Setări';

  @override
  String get modeBadge => 'DEMO';

  @override
  String get modeRealAlarm => 'Alarmă reală în Canary Live';

  @override
  String get live => 'Live';

  @override
  String get reconnecting => 'Se reconectează…';

  @override
  String get allClear => 'Totul e în regulă';

  @override
  String get evacuateNow => 'EVACUAȚI ACUM';

  @override
  String get onboardingTagline => 'Siguranța clădirii, pentru locatari';

  @override
  String get username => 'Utilizator';

  @override
  String get buildingId => 'ID clădire';

  @override
  String get linkMyUnit => 'Conectează-mi apartamentul';

  @override
  String serverAddress(String url) {
    return 'Server: $url';
  }

  @override
  String get hubSearching => 'Caut hubul…';

  @override
  String get hubNotFound =>
      'Niciun hub găsit pe acest Wi-Fi. Verifică dacă telefonul este conectat la Wi-Fi-ul clădirii.';

  @override
  String get hubRetry => 'Caută din nou';

  @override
  String get hubManualLabel => 'Adresa hubului (ex. 10.0.0.5)';

  @override
  String get hubManualConnect => 'Conectează';

  @override
  String get hubManualFailed => 'Niciun hub nu răspunde la această adresă.';

  @override
  String loginFailed(String reason) {
    return 'Autentificarea a eșuat: $reason';
  }

  @override
  String get serverUnreachable =>
      'Serverul nu poate fi contactat. Verifică conexiunea.';

  @override
  String serverError(int code) {
    return 'Eroare de server ($code)';
  }

  @override
  String get openEvacuationGuidance => 'Deschide instrucțiunile de evacuare';

  @override
  String get activeIncidents => 'Incidente active';

  @override
  String get noActiveIncidents => 'Niciun incident activ';

  @override
  String get yourBuildingMonitored => 'Clădirea ta este monitorizată.';

  @override
  String get buildingMonitored => 'Clădirea este monitorizată.';

  @override
  String get noActiveHazard =>
      'Niciun pericol activ. Vei fi alertat imediat dacă se detectează ceva.';

  @override
  String get noActiveHazardInBuilding =>
      'Niciun pericol activ în această clădire.';

  @override
  String checkInsQueued(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString de confirmări în așteptare',
      few: '$countString confirmări în așteptare',
      one: 'O confirmare în așteptare',
    );
    return '$_temp0';
  }

  @override
  String get hazardGasLeak => 'Scurgere de gaz';

  @override
  String get hazardCarbonMonoxide => 'Monoxid de carbon';

  @override
  String get hazardWaterLeak => 'Scurgere de apă';

  @override
  String get hazardSmoke => 'Fum / particule';

  @override
  String get stateNormal => 'normal';

  @override
  String get stateDetection => 'detectare';

  @override
  String get stateVerification => 'verificare';

  @override
  String get stateAlarm => 'alarmă';

  @override
  String get stateEscalation => 'escaladare';

  @override
  String get stateEvacuation => 'evacuare';

  @override
  String get stateResolution => 'rezolvat';

  @override
  String get stateFalseAlarm => 'alarmă falsă';

  @override
  String get levelOk => 'ok';

  @override
  String get levelAttention => 'atenție';

  @override
  String get levelDanger => 'pericol';

  @override
  String get levelUnknown => 'necunoscut';

  @override
  String get statusOffline => 'deconectat';

  @override
  String get statusNoData => 'fără date';

  @override
  String get occupied => 'ocupat';

  @override
  String get empty => 'liber';

  @override
  String get homeStatus => 'Starea locuinței';

  @override
  String get buildingSensors => 'Senzorii clădirii';

  @override
  String get statusNeedsAttention => 'Necesită atenție';

  @override
  String get statusDanger => 'Pericol';

  @override
  String get statusUnknown => 'Stare necunoscută';

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
      other: '$onlineString din $totalString de senzori online',
      few: '$onlineString din $totalString senzori online',
      one: '$onlineString din 1 senzor online',
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
      other: '$countString de incidente active',
      few: '$countString incidente active',
      one: '1 incident activ',
    );
    return '$_temp0';
  }

  @override
  String get noRecentData => 'Fără date recente';

  @override
  String get sensorOffline => 'Deconectat';

  @override
  String lastSeen(String status, String when) {
    return '$status · ultimul semnal $when';
  }

  @override
  String get kindAir => 'Senzor de aer';

  @override
  String get kindWater => 'Senzor de apă';

  @override
  String get kindSensor => 'Senzor';

  @override
  String get whatToDo => 'Ce trebuie să faci';

  @override
  String get indicatorAirQuality => 'Calitatea aerului';

  @override
  String get indicatorCo => 'Monoxid de carbon';

  @override
  String get indicatorGas => 'Gaz';

  @override
  String get indicatorComfort => 'Confort';

  @override
  String get indicatorOccupancy => 'Prezență';

  @override
  String get indicatorLeak => 'Scurgere de apă';

  @override
  String get indicatorValve => 'Robinet de apă';

  @override
  String get trendRising => 'în creștere';

  @override
  String get trendFalling => 'în scădere';

  @override
  String get trendStable => 'stabil';

  @override
  String get loadingSensorStatus => 'Se încarcă starea senzorilor…';

  @override
  String get sensorStatusUnavailable => 'Starea senzorilor nu este disponibilă';

  @override
  String get hubUnreachable =>
      'Hubul nu poate fi contactat acum. Trage în jos pentru a reîncerca.';

  @override
  String get noSensorsConnected => 'Niciun senzor conectat';

  @override
  String get noSensorsHint =>
      'Starea senzorilor apare aici după ce un dispozitiv Canary se conectează la hub.';

  @override
  String get refreshFailed => 'Starea senzorilor nu a putut fi actualizată';

  @override
  String refreshFailedShowingFrom(String time) {
    return 'Actualizare eșuată · se afișează starea de la $time';
  }

  @override
  String get timeJustNow => 'chiar acum';

  @override
  String minutesAgo(int minutes) {
    final intl.NumberFormat minutesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String minutesString = minutesNumberFormat.format(minutes);

    return 'acum $minutesString min';
  }

  @override
  String hoursAgo(int hours) {
    final intl.NumberFormat hoursNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String hoursString = hoursNumberFormat.format(hours);

    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'acum $hoursString de ore',
      few: 'acum $hoursString ore',
      one: 'acum o oră',
    );
    return '$_temp0';
  }

  @override
  String get offlineShowingSavedRoute =>
      'Fără conexiune · se afișează traseul salvat';

  @override
  String get minimize => 'Minimizează';

  @override
  String get dontGas =>
      'Nu folosi liftul, întrerupătoarele sau flacăra deschisă.';

  @override
  String get dontCo => 'Nu rămâne înăuntru. Ieși acum la aer curat.';

  @override
  String get dontSmoke => 'Stai aplecat sub fum. Nu folosi liftul.';

  @override
  String get dontWaterLeak =>
      'Nu atinge aparatele electrice sau întrerupătoarele de lângă apă.';

  @override
  String get dontDefault => 'Nu folosi liftul.';

  @override
  String get routeCrossesHazard =>
      'Acest traseu trece pe lângă pericol. Folosește altă ieșire marcată dacă poți și sună la 112.';

  @override
  String get routeUnchecked =>
      'Nu am putut verifica acest traseu față de pericol. Urmează ieșirile marcate, ține-te departe de pericol și sună la 112 dacă nu ești sigur.';

  @override
  String get evacuationRoute => 'Traseu de evacuare';

  @override
  String get useNearestExit => 'Folosește cea mai apropiată ieșire marcată';

  @override
  String get useNearestExitDetail =>
      'Coboară pe scări (nu cu liftul) până la punctul de adunare din exterior. Nu te întoarce înăuntru.';

  @override
  String checkInSent(String status) {
    return 'Confirmare trimisă: $status';
  }

  @override
  String get checkInQueued =>
      'Fără conexiune — confirmarea a fost salvată și se va trimite automat';

  @override
  String get dial112 => 'Formează 112 de pe telefon';

  @override
  String checkedIn(String status) {
    return 'Confirmat: $status';
  }

  @override
  String get change => 'Schimbă';

  @override
  String get imOutAndSafe => 'Am ieșit, sunt în siguranță';

  @override
  String get iNeedHelp => 'Am nevoie de ajutor';

  @override
  String get call112 => 'Sună la 112';

  @override
  String get imSafeStillInside => 'Sunt bine, dar încă înăuntru';

  @override
  String get hazardCleared => 'Pericolul a trecut.';

  @override
  String get returnAction => 'Înapoi';

  @override
  String get startHere => 'Începe aici';

  @override
  String avoidZone(String zone) {
    return 'Evită: $zone';
  }

  @override
  String routeStep(int step, int total, String label) {
    return 'Pasul $step din $total: $label.';
  }

  @override
  String get evacuationOrdered => 'Evacuarea a fost ordonată';

  @override
  String get incidentResolved => 'Incidentul a fost rezolvat';

  @override
  String get incidentDismissed => 'Incidentul a fost respins';

  @override
  String actionFailed(String reason) {
    return 'Acțiunea a eșuat: $reason';
  }

  @override
  String get victimAccounting => 'Evidența ocupanților';

  @override
  String get couldNotLoadAccounting => 'Evidența nu a putut fi încărcată';

  @override
  String get metricOccupants => 'Ocupanți';

  @override
  String get metricAccounted => 'Confirmați';

  @override
  String get metricUnaccounted => 'Neconfirmați';

  @override
  String get metricNeedHelp => 'Au nevoie de ajutor';

  @override
  String get residentAccountability => 'Situația locatarilor';

  @override
  String get couldNotLoadRoster => 'Lista locatarilor nu a putut fi încărcată';

  @override
  String get noResidentsRegistered => 'Niciun locatar înregistrat.';

  @override
  String get rosterNeedsHelp => 'ARE NEVOIE DE AJUTOR';

  @override
  String get rosterSafeOutside => 'În siguranță — afară';

  @override
  String get rosterSafeInside => 'În siguranță — înăuntru';

  @override
  String get rosterNoResponse => 'Fără răspuns';

  @override
  String get rosterAwaiting => 'În așteptare';

  @override
  String get orderEvacuation => 'Ordonă evacuarea';

  @override
  String get resolve => 'Rezolvă';

  @override
  String get dismiss => 'Respinge';

  @override
  String get account => 'Contul meu';

  @override
  String get roleResident => 'Locatar';

  @override
  String get roleManager => 'Administrator de bloc';

  @override
  String get roleDispatcher => 'Dispecer';

  @override
  String get roleAdmin => 'Administrator de sistem';

  @override
  String get presenceContribution => 'Partajarea prezenței';

  @override
  String get sharePresence => 'Partajează-mi prezența în timpul incidentelor';

  @override
  String get sharePresenceDetail =>
      'Ajută echipele de intervenție să știe cine se află înăuntru. Anonim; folosit doar în timpul unui incident activ.';

  @override
  String get about => 'Despre';

  @override
  String get aboutAppName => 'Canary pentru locatari';

  @override
  String aboutDisclaimer(String version) {
    return 'v$version — aplicație de siguranță cu rol consultativ. Nu înlocuiește alarmele certificate.';
  }

  @override
  String get server => 'Server';

  @override
  String get signOut => 'Deconectare';

  @override
  String get notificationChannelName => 'Alerte de urgență';

  @override
  String get notificationChannelDescription =>
      'Alarme critice de siguranță în clădire (gaz, CO, evacuare).';

  @override
  String notifAlarmTitle(String hazard) {
    return 'ALARMĂ: $hazard';
  }

  @override
  String notifAlarmBody(String hazard) {
    return 'Pericol detectat: $hazard. Pregătește-te de evacuare. Urmează instrucțiunile.';
  }

  @override
  String get notifAlarmBodyWaterLeak =>
      'Scurgere de apă detectată. Dacă există un robinet cu închidere automată, acesta s-a închis. Evită zona și verifică apartamentul.';

  @override
  String get notifAlarmBodySmoke =>
      'Fum sau particule în concentrație mare. Verifică dacă e fum sau foc și aerisește dacă poți face asta în siguranță. Dacă e un incendiu, ieși și sună la 112.';

  @override
  String notifEvacuateTitle(String hazard) {
    return 'EVACUAȚI ACUM — $hazard';
  }

  @override
  String get notifEvacuateBody =>
      'Ieși pe traseul sigur până la punctul de adunare. Confirmă când ești în siguranță.';

  @override
  String notifEscalatedTitle(String hazard) {
    return '$hazard: incident escaladat';
  }

  @override
  String get notifEscalatedBody =>
      'Incidentul a fost escaladat către dispecerat și serviciile de urgență.';

  @override
  String notifAlertTitle(String hazard) {
    return 'Alertă: $hazard';
  }

  @override
  String get notifOpenForGuidance => 'Deschide Canary pentru instrucțiuni.';

  @override
  String get pushFallbackTitle => 'Alertă Canary';

  @override
  String get measurements => 'Măsurători';

  @override
  String get rangeHourShort => '1h';

  @override
  String get range24hShort => '24h';

  @override
  String get range7dShort => '7z';

  @override
  String get rangeHour => 'Ultima oră';

  @override
  String get range24h => '24 de ore';

  @override
  String get range7d => '7 zile';

  @override
  String get inLastHour => 'în ultima oră';

  @override
  String get inLast24h => 'în ultimele 24 de ore';

  @override
  String get inLast7d => 'în ultimele 7 zile';

  @override
  String get tileTemperature => 'Temperatură';

  @override
  String get tileHumidity => 'Umiditate';

  @override
  String get tileFineParticles => 'Particule fine (PM2.5)';

  @override
  String get tileParticles => 'Particule (PM10)';

  @override
  String get tileGas => 'Nivel gaz';

  @override
  String get tileLeak => 'Scurgere';

  @override
  String get tileValve => 'Robinet';

  @override
  String get chipAir => 'Aer';

  @override
  String get chipWater => 'Apă';

  @override
  String get noLeaks => 'Fără scurgeri';

  @override
  String get gasOfWarning => 'din pragul de alertă';

  @override
  String get verdictGood => 'Bună';

  @override
  String get verdictModerate => 'Moderată';

  @override
  String get verdictPoor => 'Slabă';

  @override
  String get verdictDanger => 'Pericol';

  @override
  String get verdictSafe => 'Sigur';

  @override
  String get verdictElevated => 'Ridicat';

  @override
  String get verdictNormal => 'Normal';

  @override
  String get verdictCool => 'Răcoare';

  @override
  String get verdictComfortable => 'Confortabil';

  @override
  String get verdictWarm => 'Cald';

  @override
  String get verdictDryAir => 'Aer uscat';

  @override
  String get verdictHumidityOk => 'Normală';

  @override
  String get verdictHumid => 'Aer umed';

  @override
  String get verdictDry => 'Uscat';

  @override
  String get verdictLeak => 'Scurgere';

  @override
  String get approx => 'Aprox.';

  @override
  String get warmingUp => 'Senzorul se încălzește';

  @override
  String get warmingUpShort => 'Se încălzește';

  @override
  String noReadings(String range) {
    return 'Nicio măsurătoare $range.';
  }

  @override
  String get historyFailed => 'Măsurătorile nu au putut fi încărcate.';

  @override
  String get retry => 'Reîncearcă';

  @override
  String lastLeak(String time) {
    return 'Ultima scurgere: $time';
  }

  @override
  String noLeakIn(String range) {
    return 'Nicio scurgere $range';
  }

  @override
  String get approxNote =>
      '≈ Aprox.: măsurată în interiorul senzorului, deci poate diferi puțin de cameră.';

  @override
  String get analysisDetails => 'Detalii analiză';

  @override
  String tileSemantics(String label, String value, String word, String min,
      String max, String range) {
    return '$label: $value, $word. Între $min și $max $range.';
  }

  @override
  String spokenTemperature(String value) {
    return 'aproximativ $value grade';
  }

  @override
  String spokenHumidity(String value) {
    return 'aproximativ $value la sută';
  }

  @override
  String spokenParticles(String value) {
    return '$value micrograme pe metru cub';
  }

  @override
  String spokenCo(String value) {
    return '$value părți pe milion';
  }

  @override
  String spokenGas(String value) {
    return '$value la sută din pragul de alertă';
  }

  @override
  String get careProfileTitle => 'Profil de urgență';

  @override
  String get careProfileSettingsSubtitle =>
      'Ajutor prioritar pentru cine din casă nu poate ieși singur';

  @override
  String get careEmptyBody =>
      'Dacă cineva din casă nu poate ieși singur la o urgență (bunica, un copil mic), adaugă-l aici. Dispeceratul și administratorul clădirii văd informațiile doar în timpul unei urgențe, ca acea persoană să fie ajutată prima.';

  @override
  String get careAddPerson => 'Adaugă persoană';

  @override
  String get careSelfBadge => 'Eu';

  @override
  String get careForMe => 'Pentru mine';

  @override
  String get careForOther => 'Altă persoană din casă';

  @override
  String get careName => 'Nume';

  @override
  String get careNameRequired => 'Scrie un nume';

  @override
  String get careUnit => 'Apartament';

  @override
  String get careNeedsLabel => 'De ce ajutor e nevoie?';

  @override
  String get careNote => 'Notă (opțional)';

  @override
  String get careNoteHint => 'Ex.: folosește cadru, doarme în camera din spate';

  @override
  String get careConsent =>
      'Sunt de acord ca aceste informații despre sănătate să fie văzute de dispecerat și de administratorul clădirii, doar în timpul unei urgențe, ca să fie ajutată mai întâi persoana care are nevoie. Pot șterge oricând. Fiecare accesare este înregistrată.';

  @override
  String get careSaveHint =>
      'Pentru a salva: bifează acordul și alege o nevoie sau scrie o notă.';

  @override
  String get careSave => 'Salvează';

  @override
  String get careNewTitle => 'Profil nou';

  @override
  String get careEditTitle => 'Modifică profilul';

  @override
  String get careDelete => 'Șterge profilul';

  @override
  String get careDeleteConfirmTitle => 'Ștergi profilul?';

  @override
  String get careDeleteConfirmBody => 'Informațiile se șterg definitiv.';

  @override
  String get cancel => 'Anulează';

  @override
  String get delete => 'Șterge';

  @override
  String get careSaved => 'Profil salvat';

  @override
  String get careDeleted => 'Profil șters';

  @override
  String get careNotActive => 'Funcția nu e activă pe acest hub.';

  @override
  String get careSelfExists => 'Ai deja un profil pentru tine.';

  @override
  String get careUnitNotYours =>
      'Acest apartament nu este asociat contului tău.';

  @override
  String get careInvalid =>
      'Verifică datele: alege cel puțin o nevoie sau scrie o notă.';

  @override
  String get careNoUnit => 'Nu am găsit apartamentul tău. Încearcă mai târziu.';

  @override
  String get careLoadFailed =>
      'Profilurile de urgență nu au putut fi încărcate.';

  @override
  String get carePrivacyNote =>
      'Se păstrează doar pe hubul clădirii, nu pe acest telefon. Apare doar în timpul unei urgențe. Poți șterge oricând.';

  @override
  String get needReducedMobility => 'Mobilitate redusă';

  @override
  String get needWheelchair => 'Scaun cu rotile';

  @override
  String get needBedridden => 'Imobilizat la pat';

  @override
  String get needHearingImpaired => 'Nu aude alarma';

  @override
  String get needVisuallyImpaired => 'Nu vede';

  @override
  String get needMedicalDevice => 'Oxigen / aparatură medicală';

  @override
  String get needYoungChild => 'Copil mic';

  @override
  String get needPet => 'Animal de companie';

  @override
  String get careHintTitle => 'Cineva din casă are nevoie de ajutor să iasă?';

  @override
  String get careHintAction => 'Adaugă un profil de urgență';

  @override
  String get householdTitle => 'Cine mai e în casă?';

  @override
  String get householdOut => 'Afară';

  @override
  String get householdInside => 'Încă înăuntru';

  @override
  String get householdNeedsHelp => 'Are nevoie de ajutor';

  @override
  String householdSent(String status) {
    return 'Trimis: $status';
  }

  @override
  String get householdSending => 'Se trimite…';

  @override
  String get householdFailed => 'Netrimis — fără conexiune.';

  @override
  String get householdLoadFailed => 'Apartamentul nu a putut fi încărcat.';

  @override
  String householdPersonSemantics(String name) {
    return '$name, unde este acum această persoană?';
  }

  @override
  String get accountName => 'Nume';

  @override
  String get accountPhone => 'Telefon';

  @override
  String get accountPhoneHint =>
      'Pe acest număr te sună dispecerul în caz de urgență';

  @override
  String get accountEmail => 'E-mail';

  @override
  String get accountRole => 'Rol';

  @override
  String get accountSaved => 'Contul a fost salvat';

  @override
  String get accountNotAvailable =>
      'Editarea contului nu e disponibilă încă pe acest hub.';

  @override
  String get accountLoadFailed => 'Contul nu a putut fi încărcat.';

  @override
  String get accountPhoneInvalid =>
      'Scrie un număr de telefon valid, de ex. 0722 123 456';

  @override
  String get accountEmailInvalid => 'Scrie o adresă de e-mail validă';

  @override
  String get accountReadOnlyNote =>
      'Utilizatorul, rolul și apartamentul sunt stabilite de administratorul clădirii.';

  @override
  String get accountEditHint => 'Modifică numele, telefonul și e-mailul';

  @override
  String get chipCoHigh => 'CO ridicat';

  @override
  String get chipCoDanger => 'CO periculos';

  @override
  String get chipGasHigh => 'Gaz ridicat';

  @override
  String get chipGasDanger => 'Gaz periculos';

  @override
  String get verifyingTitle => 'Se verifică o posibilă problemă';

  @override
  String get verifyingCalm =>
      'Încă nu e nevoie să ieși. Te anunțăm imediat dacă trebuie.';

  @override
  String get attentionBody =>
      'Niciun pericol activ. Vezi mai jos camera marcată.';

  @override
  String get dangerBody =>
      'Verifică mai jos camera marcată și urmează sfaturile.';

  @override
  String get statusUnknownBody =>
      'Senzorii nu au trimis încă date. Starea apare aici imediat ce sosesc.';

  @override
  String get healthImportButton => 'Importă din Sănătate (Apple)';

  @override
  String get healthImporting => 'Se citesc datele din Sănătate…';

  @override
  String get healthFoundTitle => 'Am găsit în Sănătate:';

  @override
  String get healthNothingFound =>
      'Nu am găsit date relevante. Poți completa manual.';

  @override
  String get healthAccessNote =>
      'iOS nu le spune aplicațiilor dacă accesul a fost refuzat. Dacă nu l-ai permis, îl poți activa din Configurări > Sănătate > Acces date și dispozitive.';

  @override
  String get healthUnavailable =>
      'Datele din Sănătate nu sunt disponibile pe acest dispozitiv.';

  @override
  String get healthReadFailed =>
      'Nu am putut citi date din Sănătate. Poți completa manual.';

  @override
  String get healthFromProfile => 'din profilul Sănătate';

  @override
  String healthFromSteadiness(String value) {
    return 'stabilitatea mersului $value %';
  }

  @override
  String healthFromAudiogram(String value) {
    return 'audiogramă: $value dB la urechea mai bună';
  }

  @override
  String get healthAdd => 'Adaugă';

  @override
  String get healthPrivacy =>
      'Se citește doar pe acest telefon. Nu se salvează nimic până nu salvezi profilul cu acordul tău.';

  @override
  String healthSuggestionSemantics(String need, String source) {
    return '$need, $source. O adaugi în profil?';
  }

  @override
  String get range6hShort => '6h';

  @override
  String get range6h => '6 ore';

  @override
  String get inLast6h => 'în ultimele 6 ore';

  @override
  String chartThresholdWarn(String value) {
    return 'Prag de alertă $value';
  }

  @override
  String chartThresholdDanger(String value) {
    return 'Prag de pericol $value';
  }

  @override
  String get chartNoData => 'fără date';

  @override
  String get chartNow => 'Acum';

  @override
  String get chartMin => 'Min';

  @override
  String get chartMean => 'Medie';

  @override
  String get chartMax => 'Max';

  @override
  String get chartWhatMeans => 'Ce înseamnă?';

  @override
  String get chartHint =>
      'Atinge și trage pe grafic ca să vezi valoarea exactă.';

  @override
  String chartAt(String time, String value) {
    return 'La ora $time: $value';
  }

  @override
  String get chartPrevMetric => 'Măsurătoarea anterioară';

  @override
  String get chartNextMetric => 'Măsurătoarea următoare';

  @override
  String get explainTemperature =>
      'Măsurată în senzor, deci aproximativă; poate arăta puțin mai cald decât camera.';

  @override
  String get explainHumidity =>
      'Măsurată în senzor, aproximativă. Confortabil în casă: cam 30–60 %.';

  @override
  String explainPm25(String warn) {
    return 'Praf fin din fum, gătit sau aerul de afară. Cu cât mai puțin, cu atât mai bine; senzorul avertizează de la $warn.';
  }

  @override
  String explainPm10(String warn) {
    return 'Praf mai mare și polen. Senzorul avertizează de la $warn.';
  }

  @override
  String explainCo(String warn) {
    return 'Monoxidul de carbon e un gaz fără miros. Senzorul te alertează de la $warn.';
  }

  @override
  String get explainGas =>
      '% din pragul de alertă al senzorului, nu o concentrație. Peste 100 % senzorul dă alarma.';

  @override
  String get explainLeak =>
      'Uscat sau ud, așa cum raportează senzorul de apă de pe podea.';

  @override
  String get homeViewList => 'Listă';

  @override
  String get homeViewSketch => 'Schiță';

  @override
  String get sketchCommonArea => 'spațiu comun';

  @override
  String get sketchAvoid => 'Evită';

  @override
  String sensorCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString de senzori',
      few: '$countString senzori',
      one: '1 senzor',
    );
    return '$_temp0';
  }

  @override
  String get sketchNoPositions =>
      'Pozițiile camerelor nu sunt cunoscute încă, așa că le afișăm în ordine.';

  @override
  String get sketchHint =>
      'O schiță a camerelor, nu la scară. Atinge o cameră pentru senzorii ei.';

  @override
  String get householdSettingsTitle => 'Apartamentul meu';

  @override
  String get householdSettingsSubtitle => 'Cine locuiește aici și invitații';

  @override
  String get householdMembers => 'Persoane cu cont';

  @override
  String householdMemberSince(String date) {
    return 'din $date';
  }

  @override
  String get householdPendingInvites => 'Invitații în așteptare';

  @override
  String householdExpires(String when) {
    return 'Expiră: $when';
  }

  @override
  String householdInviteFor(String name) {
    return 'pentru $name';
  }

  @override
  String get householdRevoke => 'Anulează invitația';

  @override
  String get householdInviteSomeone => 'Invită pe cineva cu cont';

  @override
  String get householdLeave => 'Părăsește apartamentul';

  @override
  String householdLeaveTitle(String unit) {
    return 'Părăsești $unit?';
  }

  @override
  String get householdLeaveBody =>
      'Nu vei mai vedea senzorii acestui apartament și nu vei mai primi alertele lui. Profilurile de urgență pe care le-ai creat pentru el se șterg.';

  @override
  String get householdLeaveConfirm => 'Ieși';

  @override
  String get householdLeft => 'Ai ieșit din apartament';

  @override
  String get householdEmpty =>
      'Niciun apartament nu este asociat contului tău.';

  @override
  String get householdTooManyInvites =>
      'Sunt deja 5 invitații în așteptare. Anulează una mai întâi.';

  @override
  String get inviteSheetTitle => 'Link de invitație';

  @override
  String get inviteCopy => 'Copiază linkul';

  @override
  String get inviteCopied => 'Link copiat';

  @override
  String get inviteSms => 'Trimite prin SMS';

  @override
  String get inviteEmail => 'Trimite pe email';

  @override
  String inviteExpiryHours(int hours) {
    final intl.NumberFormat hoursNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String hoursString = hoursNumberFormat.format(hours);

    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: 'Expiră în $hoursString de ore, o singură folosire.',
      few: 'Expiră în $hoursString ore, o singură folosire.',
      one: 'Expiră într-o oră, o singură folosire.',
    );
    return '$_temp0';
  }

  @override
  String inviteMessage(String unit, String url) {
    return 'Intră în apartamentul nostru ($unit) în Canary: $url';
  }

  @override
  String get inviteEmailSubject => 'Invitație Canary';

  @override
  String get careInviteMember => 'Are cont propriu? Trimite-i invitație';

  @override
  String get inviteCodeEntry => 'Am un cod de invitație';

  @override
  String get inviteCodeLabel => 'Cod de invitație';

  @override
  String get inviteCodeHint => 'Lipește codul sau tot linkul';

  @override
  String get inviteCodeInvalid => 'Nu pare un cod de invitație.';

  @override
  String get inviteContinue => 'Continuă';

  @override
  String get inviteTitle => 'Invitație';

  @override
  String inviteFrom(String inviter) {
    return '$inviter te invită în';
  }

  @override
  String get inviteBuilding => 'Clădire';

  @override
  String get inviteFloor => 'Etaj';

  @override
  String inviteCareOffer(String inviter, String name) {
    return '$inviter a creat un profil de urgență pentru tine ($name). Vrei să-l preiei?';
  }

  @override
  String get inviteTakeOver => 'Da, preiau profilul';

  @override
  String get inviteAccept => 'Acceptă';

  @override
  String get inviteDecline => 'Refuză';

  @override
  String inviteAccepted(String unit) {
    return 'Ai intrat în $unit';
  }

  @override
  String get inviteInvalid =>
      'Invitația nu mai e valabilă (expirată, folosită sau greșită).';

  @override
  String get inviteStaff => 'Doar locatarii pot intra într-un apartament.';

  @override
  String get inviteConflict =>
      'Nu poți accepta propria invitație sau ai deja un profil de urgență pentru tine.';

  @override
  String get inviteNeedsConsent => 'Bifează acordul ca să preiei profilul.';

  @override
  String get inviteTooMany =>
      'Prea multe încercări. Încearcă din nou mai târziu.';

  @override
  String get inviteLoginFirst => 'Intră în cont ca să accepți invitația.';

  @override
  String get inviteLoading => 'Se încarcă invitația…';

  @override
  String get testSectionTitle => 'Testează senzorul';

  @override
  String get testAlarmButton => 'Testează alarma (4 s)';

  @override
  String get testAlarmHint => 'Senzorul va suna și va clipi 4 secunde.';

  @override
  String get silenceAlarmButton => 'Oprește alarma';

  @override
  String get closeValveButton => 'Închide robinetul';

  @override
  String get openValveButton => 'Deschide robinetul';

  @override
  String get closeValveConfirmTitle => 'Închizi robinetul?';

  @override
  String get closeValveConfirmBody =>
      'Robinetul va opri apa în apartament până îl redeschizi.';

  @override
  String get commonAreaTestNote =>
      'Doar administratorul poate testa senzorii din spațiile comune.';

  @override
  String get testOfflineNote =>
      'Senzorul e deconectat. Îl poți testa când revine.';

  @override
  String get runSent => 'Trimis…';

  @override
  String get runAccepted => 'Reușit';

  @override
  String runRejected(String reason) {
    return 'Respins: $reason';
  }

  @override
  String get runRejectedPlain => 'Respins';

  @override
  String get runTimeout => 'Fără răspuns';

  @override
  String get runTimeoutHint => 'Senzorul nu a răspuns în 15 secunde.';

  @override
  String runFailed(String reason) {
    return 'Nu s-a trimis: $reason';
  }

  @override
  String get commandTest => 'Test alarmă';

  @override
  String get commandSilence => 'Oprire alarmă';

  @override
  String get commandOpen => 'Deschidere robinet';

  @override
  String get commandClose => 'Închidere robinet';

  @override
  String get cmdErrOffline => 'senzorul e deconectat';

  @override
  String get cmdErrTooSoon => 'așteaptă câteva secunde între comenzi';

  @override
  String get cmdErrNotYours => 'senzorul nu e în apartamentul tău';

  @override
  String get cmdErrInvalid => 'senzorul nu primește această comandă';

  @override
  String get cmdErrForbidden => 'contul tău nu poate trimite comenzi';

  @override
  String get detailSelfTest => 'autotest pornit';

  @override
  String get detailSilenced => 'alarmă oprită';

  @override
  String get detailSelfTestBusy => 'un autotest rulează deja';

  @override
  String get detailAlarmInactive => 'nicio alarmă activă';

  @override
  String get detailOpen => 'robinet deschis';

  @override
  String get detailClosed => 'robinet închis';

  @override
  String get detailBusy => 'senzorul e ocupat cu altă comandă';

  @override
  String get detailInvalidCommand => 'senzorul nu cunoaște comanda';

  @override
  String get detailSensorWet => 'senzorul detectează încă apă';

  @override
  String get detailSensorUninitialized => 'senzorul încă pornește';

  @override
  String get detailOtaActive => 'senzorul se actualizează';

  @override
  String get detailCommandRejected => 'senzorul a refuzat comanda';

  @override
  String get detailPersistenceFailed => 'starea robinetului nu s-a putut salva';

  @override
  String lastTest(String result, String when) {
    return 'Ultimul test: $result · $when';
  }

  @override
  String get lastTestNone => 'Netestat';

  @override
  String get lastTestAccepted => 'reușit';

  @override
  String get lastTestRejected => 'respins';

  @override
  String get lastTestTimeout => 'fără răspuns';

  @override
  String get lastTestSent => 'în curs';

  @override
  String get testMySensors => 'Testează-mi senzorii';

  @override
  String get testMySensorsSubtitle => 'Fă fiecare senzor să sune scurt';

  @override
  String get testBuildingSensors => 'Testează senzorii';

  @override
  String get testBuildingSensorsSubtitle => 'Toți senzorii clădirii, pe camere';

  @override
  String get testAllAlarms => 'Testează toate alarmele';

  @override
  String get testAllHint =>
      'Senzorii de aer din apartament sună pe rând, câte 4 secunde. Robinetele de apă nu se închid.';

  @override
  String testAllRunning(int done, int total) {
    final intl.NumberFormat doneNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String doneString = doneNumberFormat.format(done);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Se testează $doneString din $totalString…';
  }

  @override
  String testAllDone(int passed, int total) {
    final intl.NumberFormat passedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String passedString = passedNumberFormat.format(passed);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Gata: $passedString din $totalString reușite';
  }

  @override
  String get testAllNoAir =>
      'Niciun senzor de aer de-al tău nu e conectat acum.';

  @override
  String get testAllNoAirHere =>
      'Niciun senzor de aer de aici nu e conectat acum.';

  @override
  String testAllAlarmsIn(String scope) {
    return 'Testează toate alarmele · $scope';
  }

  @override
  String get testAllPickUnit =>
      'Alege un apartament de sus ca să-i testezi toate alarmele deodată.';

  @override
  String get scopeWholeBuilding => 'Toată clădirea';

  @override
  String get scopeAllHomes => 'Toate';

  @override
  String get scopeAllRooms => 'Toate camerele';

  @override
  String get scopePickUnit => 'Alege apartamentul';

  @override
  String get scopePickRoom => 'Alege camera';

  @override
  String get checklistWaiting => 'În așteptare';

  @override
  String get checklistSkipped => 'Deconectat, sărit';

  @override
  String get noOwnSensors => 'Nu am găsit senzori în apartamentul tău.';

  @override
  String get statusOnline => 'conectat';

  @override
  String lastTestNoTime(String result) {
    return 'Ultimul test: $result';
  }

  @override
  String get cmdErrHubOffline => 'hub-ul nu e conectat la senzori acum';

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
  String get homeAllWell => 'Totul e în regulă';

  @override
  String get homeMonitored => 'Locuința ta e monitorizată';

  @override
  String get homeEvacuateLine => 'Ieși acum pe scări, nu cu liftul.';

  @override
  String get myRooms => 'Camerele mele';

  @override
  String get buildingSection => 'Clădirea';

  @override
  String get buildingNoIncidents => 'Clădirea: niciun incident activ';

  @override
  String buildingIncident(String hazard) {
    return 'Clădirea: $hazard';
  }

  @override
  String get allSensors => 'Toți senzorii';

  @override
  String get showSensors => 'Arată senzorii';

  @override
  String get hideSensors => 'Ascunde senzorii';

  @override
  String get expandSection => 'Arată';

  @override
  String get collapseSection => 'Ascunde';

  @override
  String get openRoom => 'Deschide camera';

  @override
  String get appearance => 'Aspect';

  @override
  String get themeAuto => 'Automat';

  @override
  String get themeLight => 'Luminos';

  @override
  String get themeDark => 'Întunecat';

  @override
  String get themeHint => 'Automat urmează setarea telefonului.';

  @override
  String whereHome(String room) {
    return 'În locuința ta: $room';
  }

  @override
  String whereMyFloor(String unit) {
    return 'Pe etajul tău: $unit';
  }

  @override
  String whereMyFloorCommon(String area) {
    return 'Pe etajul tău: $area (spațiu comun)';
  }

  @override
  String whereOtherFloor(String place) {
    return 'Pe alt etaj: $place';
  }

  @override
  String whereCommonArea(String area) {
    return 'Într-un spațiu comun: $area';
  }

  @override
  String whereBuilding(String place) {
    return 'În clădire: $place';
  }

  @override
  String get whereUnknown => 'În clădire (locul exact nu e cunoscut încă)';

  @override
  String youAre(String home) {
    return 'Tu: $home';
  }

  @override
  String get whereNowQuestion => 'Unde ești acum?';

  @override
  String get whereNowWhy => 'Răspunsul tău ajunge la administratorul clădirii.';

  @override
  String get whereNowHome => 'Acasă';

  @override
  String get whereNowBuilding => 'În altă parte în clădire';

  @override
  String get whereNowOutside => 'Afară';

  @override
  String whereYouSaid(String where) {
    return 'Ești: $where';
  }

  @override
  String whereSent(String where) {
    return 'Trimis: $where';
  }

  @override
  String get whereNotSent =>
      'Nu s-a trimis: fără conexiune. Răspunsul e salvat pe telefon; apasă din nou ca să-l trimiți.';

  @override
  String get adviceLeaveHomeNow =>
      'Pericolul e în locuința ta. Ieși acum, închide ușa după tine și coboară pe scări.';

  @override
  String get adviceLeaveHome =>
      'Ia telefonul și cheile, închide ușa după tine și ieși pe traseul de mai jos.';

  @override
  String get adviceGetReady =>
      'Pregătește-te să ieși: telefon, chei, încălțări. Ieși imediat dacă ți se cere sau dacă pericolul se apropie.';

  @override
  String get adviceLeaveBuilding =>
      'Ieși pe cea mai apropiată scară. Nu te întoarce după lucruri și nu folosi liftul.';

  @override
  String adviceStayOut(String point) {
    return 'Rămâi afară și mergi la punctul de adunare: $point. Nu intra înapoi până nu ți se spune că e sigur.';
  }

  @override
  String get adviceStayOutNoPoint =>
      'Rămâi afară, departe de clădire. Nu intra înapoi până nu ți se spune că e sigur.';

  @override
  String get dangerPlanTitle => 'Unde e pericolul';

  @override
  String planCaption(String floor) {
    return '$floor · schiță, nu la scară';
  }

  @override
  String get planCaptionNoFloor => 'Schiță, nu la scară';

  @override
  String get planYou => 'Tu';

  @override
  String get planDanger => 'Pericol';

  @override
  String get planExit => 'Ieșire';

  @override
  String get affectedRoomsTitle => 'Camere afectate';

  @override
  String get roomTagSource => 'sursa';

  @override
  String get roomTagYours => 'locuința ta';
}

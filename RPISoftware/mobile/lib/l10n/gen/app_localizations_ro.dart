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
  String get evacuateNow => 'EVACUAȚI ACUM';

  @override
  String get minimize => 'Minimizează';

  @override
  String get call112 => 'Sunați la 112';

  @override
  String get dial112 => 'Sunați la 112 de pe telefon';

  @override
  String get allClear => 'Pericol înlăturat';

  @override
  String get hazardCleared => 'Pericolul a fost înlăturat.';

  @override
  String get returnLabel => 'Înapoi';

  @override
  String get gasLeak => 'Scurgere de gaz';

  @override
  String get carbonMonoxide => 'Monoxid de carbon';

  @override
  String get waterLeak => 'Scurgere de apă';

  @override
  String get smokeParticulates => 'Fum / particule';

  @override
  String get hazardGasDont =>
      'Nu folosiți liftul sau întrerupătoarele și nu aprindeți flăcări.';

  @override
  String get hazardCoDont =>
      'Nu rămâneți înăuntru. Ieșiți imediat la aer curat.';

  @override
  String get hazardSmokeDont =>
      'Deplasați-vă aplecat, sub nivelul fumului. Nu folosiți liftul.';

  @override
  String get hazardWaterDont =>
      'Nu atingeți aparate electrice sau întrerupătoare lângă apă.';

  @override
  String get hazardDefaultDont => 'Nu folosiți liftul.';

  @override
  String get stateDetection => 'Detectat';

  @override
  String get stateVerification => 'Se verifică';

  @override
  String get stateAlarm => 'Alarmă';

  @override
  String get stateEvacuation => 'Evacuați acum';

  @override
  String get stateEscalation => 'Intervenție de urgență';

  @override
  String get stateResolution => 'Rezolvat';

  @override
  String get stateFalseAlarm => 'Alarmă falsă';

  @override
  String get stateNormal => 'Fără pericol';

  @override
  String get safeOutside => 'Sunt afară, în siguranță';

  @override
  String get safeInside => 'Sunt în siguranță, dar încă înăuntru';

  @override
  String get needsHelp => 'Am nevoie de ajutor';

  @override
  String get liveJustNow => 'Conectat · actualizat chiar acum';

  @override
  String liveUpdated(int seconds) {
    return 'Conectat · actualizat acum $seconds s';
  }

  @override
  String get offlineSavedRoute => 'Fără conexiune · se afișează ruta salvată';

  @override
  String get offlineNoRoute => 'Fără conexiune · nu există rută disponibilă';

  @override
  String get routeCrossesHazard =>
      'Această rută trece pe lângă pericol. Folosiți o altă ieșire marcată dacă puteți și sunați la 112.';

  @override
  String get routeSafetyUnknown =>
      'Nu am putut verifica această rută față de pericol. Urmați ieșirile marcate, stați departe de pericol și sunați la 112 în caz de dubiu.';

  @override
  String get evacuationRoute => 'Rută de evacuare';

  @override
  String get readAloud => 'Citiți cu voce tare';

  @override
  String get stopReading => 'Opriți';

  @override
  String spokenAssembly(Object name) {
    return 'Apoi mergeți la punctul de adunare: $name.';
  }

  @override
  String get fallbackLeave =>
      'Ieșiți pe cea mai apropiată ieșire sigură. Nu folosiți liftul.';

  @override
  String get fallbackAssembly =>
      'Mergeți la punctul exterior de adunare și nu vă întoarceți înăuntru.';

  @override
  String checkInSent(Object status) {
    return 'Confirmare trimisă: $status';
  }

  @override
  String get checkInQueued =>
      'Fără conexiune — confirmarea va fi trimisă automat';

  @override
  String checkedIn(Object status) {
    return 'Confirmat: $status';
  }

  @override
  String get change => 'Modifică';

  @override
  String get outAndSafe => 'Sunt afară, în siguranță';

  @override
  String get safeStillInside => 'Sunt în siguranță, dar încă înăuntru';

  @override
  String savedRoute(Object time) {
    return 'Rută salvată la $time — este posibil să nu reflecte blocajele actuale';
  }

  @override
  String get startHere => 'Porniți de aici';

  @override
  String avoid(Object name) {
    return 'Evitați: $name';
  }

  @override
  String routeStep(int step, int total, Object label, Object hint) {
    return 'Pasul $step din $total: $label.$hint';
  }

  @override
  String get live => 'Conectat';

  @override
  String get reconnecting => 'Se reconectează…';

  @override
  String checkInsQueued(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de confirmări în așteptare',
      few: '$count confirmări în așteptare',
      one: 'O confirmare în așteptare',
      zero: 'Nicio confirmare în așteptare',
    );
    return '$_temp0';
  }

  @override
  String get openEvacuationGuidance => 'Deschideți ghidul de evacuare';

  @override
  String get activeIncidents => 'Incidente active';

  @override
  String get noActiveIncidents => 'Nu există incidente active';

  @override
  String get buildingMonitored => 'Clădirea dumneavoastră este monitorizată.';

  @override
  String get noActiveHazard =>
      'Nu există pericol activ. Vă vom alerta imediat dacă se detectează ceva.';

  @override
  String get settings => 'Setări';

  @override
  String get account => 'Cont';

  @override
  String get presenceContribution => 'Contribuție la prezență';

  @override
  String get sharePresence => 'Partajați prezența în timpul incidentelor';

  @override
  String get sharePresenceDescription =>
      'Ajută echipele de intervenție să știe mai bine cine este înăuntru. Date anonime, folosite numai la un incident activ.';

  @override
  String get about => 'Despre';

  @override
  String get canaryResident => 'Canary pentru rezidenți';

  @override
  String get appVersion =>
      'v0.1.0 — aplicație de siguranță informativă. Nu înlocuiește alarmele certificate.';

  @override
  String get server => 'Server';

  @override
  String get signOut => 'Deconectare';

  @override
  String get residentSafety => 'Siguranța clădirii pentru rezidenți';

  @override
  String get username => 'Nume utilizator';

  @override
  String get buildingId => 'ID clădire';

  @override
  String get linkUnit => 'Conectează locuința';

  @override
  String serverValue(Object server) {
    return 'Server: $server';
  }

  @override
  String get orderEvacuation => 'Dispune evacuarea';

  @override
  String get resolve => 'Rezolvă';

  @override
  String get dismiss => 'Închide';

  @override
  String doneAction(Object action) {
    return 'Finalizat: $action';
  }

  @override
  String get victimAccounting => 'Evidența persoanelor';

  @override
  String get couldNotLoadAccounting => 'Nu s-a putut încărca evidența';

  @override
  String get occupants => 'Persoane';

  @override
  String get accounted => 'Confirmate';

  @override
  String get unaccounted => 'Neconfirmate';

  @override
  String get needHelp => 'Au nevoie de ajutor';

  @override
  String get residentAccountability => 'Evidența rezidenților';

  @override
  String get couldNotLoadRoster => 'Nu s-a putut încărca lista';

  @override
  String get noResidents => 'Nu există rezidenți înregistrați.';

  @override
  String get needsHelpUpper => 'AU NEVOIE DE AJUTOR';

  @override
  String get safeOut => 'În siguranță — afară';

  @override
  String get safeIn => 'În siguranță — înăuntru';

  @override
  String get noResponse => 'Fără răspuns';

  @override
  String get awaiting => 'În așteptare';

  @override
  String get buildingSensors => 'Senzorii clădirii';

  @override
  String get homeStatus => 'Starea locuinței';

  @override
  String sensorsOnline(int online, int total) {
    return '$online din $total senzori online';
  }

  @override
  String activeIncidentCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count de incidente active',
      few: '$count incidente active',
      one: '1 incident activ',
    );
    return '$_temp0';
  }

  @override
  String get occupied => 'ocupat';

  @override
  String get empty => 'liber';

  @override
  String get noData => 'fără date';

  @override
  String get noRecentData => 'Fără date recente';

  @override
  String get offline => 'Fără conexiune';

  @override
  String lastSeen(Object what, Object time) {
    return '$what · văzut ultima dată $time';
  }

  @override
  String get whatToDo => 'Ce aveți de făcut';

  @override
  String get loadingSensorStatus => 'Se încarcă starea senzorilor…';

  @override
  String get sensorStatusUnavailable => 'Starea senzorilor nu este disponibilă';

  @override
  String get cannotReachHub =>
      'Nu se poate contacta hub-ul acum. Trageți în jos pentru reîncercare.';

  @override
  String get noSensors => 'Nu sunt conectați senzori';

  @override
  String get sensorStatusAppears =>
      'Starea senzorilor apare aici după ce un dispozitiv Canary se conectează la hub.';

  @override
  String get couldNotRefresh => 'Nu s-a putut actualiza starea senzorilor';

  @override
  String couldNotRefreshFrom(Object time) {
    return 'Nu s-a putut actualiza · se afișează starea de la $time';
  }

  @override
  String get needsAttention => 'Necesită atenție';

  @override
  String get danger => 'Pericol';

  @override
  String get statusUnknown => 'Stare necunoscută';

  @override
  String get airSensor => 'Senzor de aer';

  @override
  String get waterSensor => 'Senzor de apă';

  @override
  String get sensor => 'Senzor';

  @override
  String get airQuality => 'Calitatea aerului';

  @override
  String get gas => 'Gaz';

  @override
  String get comfort => 'Confort';

  @override
  String get occupancy => 'Ocupare';

  @override
  String get waterValve => 'Valvă de apă';

  @override
  String get justNow => 'chiar acum';

  @override
  String minutesAgo(int count) {
    return 'acum $count min';
  }

  @override
  String hoursAgo(int count) {
    return 'acum $count h';
  }

  @override
  String daysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'acum $count de zile',
      few: 'acum $count zile',
      one: 'acum o zi',
    );
    return '$_temp0';
  }

  @override
  String get notificationChannelName => 'Alerte de urgență';

  @override
  String get notificationChannelDescription =>
      'Alarme critice pentru siguranța clădirii (gaz, CO, evacuare).';

  @override
  String alertNotificationTitle(Object hazard) {
    return 'Alertă: $hazard';
  }

  @override
  String get openAppForGuidance => 'Deschideți Canary pentru instrucțiuni.';

  @override
  String get loginFailed => 'Autentificarea nu a reușit. Încercați din nou.';

  @override
  String get actionFailed =>
      'Acțiunea nu a putut fi finalizată. Încercați din nou.';

  @override
  String get seeFloorPlan => 'Vedeți pe schiță';

  @override
  String get hideFloorPlan => 'Ascundeți schița';

  @override
  String get floorPlanNotToScale => 'Schemă orientativă · nu la scară';

  @override
  String get assemblyPoint => 'Punct de adunare';

  @override
  String floorPlanSemantics(Object start, Object end) {
    return 'Schiță orientativă, nu la scară. Traseu de la $start până la $end.';
  }
}

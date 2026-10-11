/// Official ISO 7010 safety signs, the pictograms the EU mandates through
/// Directive 92/58/EEC and Romania through HG 971/2006 (SR EN ISO 7010).
///
/// `assets/signs/<code>.png` are Wikimedia Commons' renders of the public-domain
/// `File:ISO_7010_<code>.svg`, unmodified; the dashboard ships the same SVGs.
/// ISO 7010 signs carry no words; `en` / `ro` name them in tooltips and for
/// screen readers, in the app language (see [nameFor]).
enum SafetySign {
  e002('E002', 'Emergency exit', 'Ieșire de urgență'),
  e004('E004', 'Emergency telephone', 'Telefon de urgență'),
  e007('E007', 'Evacuation assembly point', 'Punct de adunare'),
  p001('P001', 'Prohibited', 'Interzis'),
  p003('P003', 'No open flame', 'Interzis focul deschis'),
  p020('P020', 'Do not use lift in the event of fire', 'Nu folosiți liftul în caz de incendiu'),
  p031('P031', 'Do not alter the state of the switch', 'Nu acționați întrerupătorul'),
  w001('W001', 'Warning', 'Atenție, pericol'),
  w011('W011', 'Slippery surface', 'Atenție, suprafață alunecoasă'),
  w016('W016', 'Toxic material', 'Atenție, substanțe toxice'),
  w021('W021', 'Flammable material', 'Atenție, materiale inflamabile');

  const SafetySign(this.code, this.en, this.ro);
  final String code;
  final String en;
  final String ro;

  String get asset => 'assets/signs/$code.png';

  /// The sign's name for an app language code ('ro' | 'en').
  String nameFor(String languageCode) => languageCode == 'ro' ? ro : en;
}

/// The ISO 7010 warning sign for a hazard type.
SafetySign hazardSign(String hazardType) => switch (hazardType) {
      'combustible_gas' => SafetySign.w021,
      'co' => SafetySign.w016,
      'water_leak' => SafetySign.w011,
      // ISO 7010 has no smoke sign; ISO 3864-1 says use the general warning.
      _ => SafetySign.w001,
    };

/// Signs that back up `hazardDont()` for the same hazard type.
List<SafetySign> hazardAdviceSigns(String hazardType) => switch (hazardType) {
      'combustible_gas' => const [SafetySign.p020, SafetySign.p031, SafetySign.p003],
      'co' => const [SafetySign.e002],
      'water_leak' => const [SafetySign.p031],
      _ => const [SafetySign.p020],
    };

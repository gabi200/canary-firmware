/// "Profil de urgență": special needs of a resident or of a household member
/// without the app, so the dispatcher / building manager can prioritise people
/// who can't evacuate alone. Health data (GDPR art. 9): it lives on the hub
/// only — the app keeps it in memory, never on disk — and is sent only with
/// the resident's explicit consent.
library;

/// Need codes (must match the backend).
enum CareNeed {
  reducedMobility('reduced_mobility'),
  wheelchair('wheelchair'),
  bedridden('bedridden'),
  hearingImpaired('hearing_impaired'),
  visuallyImpaired('visually_impaired'),
  medicalDevice('medical_device'),
  youngChild('young_child'),
  pet('pet');

  const CareNeed(this.code);
  final String code;

  static CareNeed? fromCode(Object? code) {
    for (final n in values) {
      if (n.code == code) return n;
    }
    return null;
  }
}

/// Longest note the hub accepts.
const careNoteMaxLength = 280;

class CareProfile {
  const CareProfile({
    required this.id,
    required this.unitId,
    required this.displayName,
    required this.isSelf,
    this.unitLabel,
    this.needs = const [],
    this.note,
    this.consentTs,
    this.updatedTs,
  });

  final String id;
  final String unitId;
  final String? unitLabel;
  final String displayName;

  /// The resident themself (at most one per account) vs a household member.
  final bool isSelf;

  /// Known needs, in [CareNeed] order; unknown codes from a newer hub are dropped.
  final List<CareNeed> needs;
  final String? note;
  final DateTime? consentTs;
  final DateTime? updatedTs;

  factory CareProfile.fromJson(Map<String, dynamic> j) {
    final rawNeeds = j['needs'];
    final needs = <CareNeed>{
      if (rawNeeds is List)
        for (final code in rawNeeds)
          if (CareNeed.fromCode(code) case final CareNeed need) need,
    };
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    return CareProfile(
      id: '${j['id']}',
      unitId: str(j['unit_id']) ?? '',
      unitLabel: str(j['unit_label']),
      displayName: str(j['display_name']) ?? '',
      isSelf: j['is_self'] == true,
      needs: CareNeed.values.where(needs.contains).toList(),
      note: str(j['note']),
      consentTs: j['consent_ts'] is String ? DateTime.tryParse(j['consent_ts'] as String) : null,
      updatedTs: j['updated_ts'] is String ? DateTime.tryParse(j['updated_ts'] as String) : null,
    );
  }
}

/// Body of POST / PUT `/me/care-profiles`.
class CareProfileDraft {
  const CareProfileDraft({
    required this.unitId,
    required this.displayName,
    required this.isSelf,
    required this.needs,
    required this.note,
    required this.consent,
  });

  final String unitId;
  final String displayName;
  final bool isSelf;
  final Set<CareNeed> needs;
  final String note;

  /// The resident ticked the explicit consent box for this save.
  final bool consent;

  Map<String, Object?> toJson() => {
        'unit_id': unitId,
        'display_name': displayName.trim(),
        'is_self': isSelf,
        'needs': [for (final n in CareNeed.values) if (needs.contains(n)) n.code],
        'note': note.trim().isEmpty ? null : note.trim(),
        'consent': consent,
      };
}

/// The form may be saved only with explicit consent, a name, a known unit, and
/// at least one need or a note (within [careNoteMaxLength]).
bool careDraftReady({
  required String name,
  required Set<CareNeed> needs,
  required String note,
  required bool consent,
  required String? unitId,
}) =>
    consent &&
    name.trim().isNotEmpty &&
    unitId != null &&
    unitId.isNotEmpty &&
    (needs.isNotEmpty || note.trim().isNotEmpty) &&
    note.length <= careNoteMaxLength;

/// One of the caller's units, for the profile form.
class UnitRef {
  const UnitRef(this.id, [this.label]);
  final String id;
  final String? label;

  @override
  bool operator ==(Object other) => other is UnitRef && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// Who the caller is, for the form: name to prefill and their unit(s).
class MyHousehold {
  const MyHousehold({required this.units, this.displayName});
  final String? displayName;
  final List<UnitRef> units;
}

/// Fallback while the hub has no "my units" endpoint: the resident's summary
/// lists only their own and common zones, and `/zones` maps each zone to its
/// unit; common-area units are dropped.
List<String> ownUnitIds({
  required Iterable<String> visibleZoneIds,
  required Map<String, String> zoneUnits,
}) {
  final ids = <String>{};
  for (final zone in visibleZoneIds) {
    final unit = zoneUnits[zone];
    if (unit == null || unit.isEmpty || unit.toLowerCase().contains('common')) continue;
    ids.add(unit);
  }
  return ids.toList()..sort();
}

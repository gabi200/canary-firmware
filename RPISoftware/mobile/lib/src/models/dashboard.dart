/// Manager/dispatcher dashboard models: victim-accounting + named resident roster.
/// Mirrors the web dashboard payloads (AccountingOut / RosterOut / ResidentOut).
library;

class ZoneOccupancy {
  const ZoneOccupancy({required this.zoneId, required this.personsEst});
  final String zoneId;
  final double personsEst;

  factory ZoneOccupancy.fromJson(Map<String, dynamic> j) => ZoneOccupancy(
        zoneId: j['zone_id'] as String,
        personsEst: (j['persons_est'] as num).toDouble(),
      );
}

class Accounting {
  const Accounting({
    required this.incidentId,
    required this.occupancyTotal,
    required this.accounted,
    required this.unaccounted,
    required this.needsHelp,
    required this.zonesWithPeople,
  });

  final String incidentId;
  final double occupancyTotal;
  final int accounted;
  final int unaccounted;
  final int needsHelp;
  final List<ZoneOccupancy> zonesWithPeople;

  factory Accounting.fromJson(Map<String, dynamic> j) => Accounting(
        incidentId: j['incident_id'] as String,
        occupancyTotal: (j['occupancy_total'] as num).toDouble(),
        accounted: (j['accounted'] as num).toInt(),
        unaccounted: (j['unaccounted'] as num).toInt(),
        needsHelp: (j['needs_help'] as num).toInt(),
        zonesWithPeople: ((j['zones_with_people'] ?? []) as List)
            .map((e) => ZoneOccupancy.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class RosterEntry {
  const RosterEntry({
    required this.userId,
    required this.displayName,
    required this.status,
    this.unitId,
    this.unitLabel,
    this.phone,
    this.ts,
  });

  final String userId;
  final String displayName;
  final String status; // safe_outside | safe_inside | needs_help | no_response | unknown
  final String? unitId;
  final String? unitLabel;
  final String? phone;
  final DateTime? ts;

  bool get needsHelp => status == 'needs_help';
  bool get isSafe => status == 'safe_outside' || status == 'safe_inside';

  factory RosterEntry.fromJson(Map<String, dynamic> j) => RosterEntry(
        userId: j['user_id'] as String,
        displayName: (j['display_name'] ?? '') as String,
        status: (j['status'] ?? 'unknown') as String,
        unitId: j['unit_id'] as String?,
        unitLabel: j['unit_label'] as String?,
        phone: j['phone'] as String?,
        ts: j['ts'] == null ? null : DateTime.tryParse(j['ts'] as String),
      );
}

class Roster {
  const Roster({
    required this.incidentId,
    required this.total,
    required this.safe,
    required this.needsHelp,
    required this.awaiting,
    required this.entries,
  });

  final String incidentId;
  final int total;
  final int safe;
  final int needsHelp;
  final int awaiting;
  final List<RosterEntry> entries;

  factory Roster.fromJson(Map<String, dynamic> j) => Roster(
        incidentId: j['incident_id'] as String,
        total: (j['total'] as num).toInt(),
        safe: (j['safe'] as num).toInt(),
        needsHelp: (j['needs_help'] as num).toInt(),
        awaiting: (j['awaiting'] as num).toInt(),
        entries: ((j['entries'] ?? []) as List)
            .map((e) => RosterEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

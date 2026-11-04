import 'care_profile.dart';

/// `GET /api/v1/me`: the signed-in account. Personal data (phone, email) is
/// held in memory only, like the rest of the account state.
class MeProfile {
  const MeProfile({
    required this.userId,
    required this.username,
    required this.role,
    this.displayName,
    this.phone,
    this.email,
    this.units = const [],
    this.otherUnitIds = const {},
  });

  final String userId;
  final String username;
  final String role;
  final String? displayName;
  final String? phone;
  final String? email;
  final List<MeUnit> units;

  /// Units of other buildings, set by [forBuilding]: not "my home" here, and
  /// what care profiles and the household list are filtered against.
  final Set<String> otherUnitIds;

  /// Only the units of [buildingId] (a unit with no building, from an older
  /// hub, stays). The hub lists a resident's units in every building.
  MeProfile forBuilding(String buildingId) => MeProfile(
        userId: userId,
        username: username,
        role: role,
        displayName: displayName,
        phone: phone,
        email: email,
        units: [for (final u in units) if (u.buildingId == null || u.buildingId == buildingId) u],
        otherUnitIds: {for (final u in units) if (u.buildingId != null && u.buildingId != buildingId) u.unitId},
      );

  /// The caller's own homes (care profiles attach to these).
  List<UnitRef> get residentialUnits => [
        for (final u in units)
          if (u.kind == null || u.kind == 'residential') UnitRef(u.unitId, u.unitLabel),
      ];

  factory MeProfile.fromJson(Map<String, dynamic> j) {
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    final rawUnits = j['units'];
    return MeProfile(
      userId: str(j['user_id']) ?? '',
      username: str(j['username']) ?? '',
      role: str(j['role']) ?? '',
      displayName: str(j['display_name']),
      phone: str(j['phone']),
      email: str(j['email']),
      units: [
        if (rawUnits is List)
          for (final u in rawUnits.whereType<Map<String, dynamic>>())
            if (str(u['unit_id']) case final String id)
              MeUnit(
                unitId: id,
                unitLabel: str(u['unit_label']),
                buildingId: str(u['building_id']),
                floorLabel: str(u['floor_label']),
                kind: str(u['kind']),
              ),
      ],
    );
  }
}

class MeUnit {
  const MeUnit({required this.unitId, this.unitLabel, this.buildingId, this.floorLabel, this.kind});
  final String unitId;
  final String? unitLabel;
  final String? buildingId;
  final String? floorLabel;

  /// residential | common
  final String? kind;
}

/// The fields `PATCH /me` may change, with what was there before; [changes]
/// holds only fields that differ ("" clears phone / email).
class AccountEdit {
  const AccountEdit({required this.original, required this.displayName, required this.phone, required this.email});
  final MeProfile original;
  final String displayName;
  final String phone;
  final String email;

  Map<String, String> get changes {
    final out = <String, String>{};
    void put(String key, String value, String? before) {
      if (value.trim() != (before ?? '').trim()) out[key] = value.trim();
    }

    put('display_name', displayName, original.displayName);
    put('phone', phone, original.phone);
    put('email', email, original.email);
    return out;
  }
}

/// Local checks before sending (the hub validates and normalizes for real).
enum AccountFieldError { nameRequired, phoneInvalid, emailInvalid }

AccountFieldError? validateDisplayName(String v) => v.trim().isEmpty ? AccountFieldError.nameRequired : null;

/// Empty clears the number; otherwise digits with optional +, spaces, dots,
/// dashes and parentheses, 6–15 digits (E.164 allows up to 15).
AccountFieldError? validatePhone(String v) {
  final t = v.trim();
  if (t.isEmpty) return null;
  if (!RegExp(r'^\+?[0-9 ().\-]+$').hasMatch(t)) return AccountFieldError.phoneInvalid;
  final digits = t.replaceAll(RegExp(r'[^0-9]'), '').length;
  return digits < 6 || digits > 15 ? AccountFieldError.phoneInvalid : null;
}

AccountFieldError? validateEmail(String v) {
  final t = v.trim();
  if (t.isEmpty) return null;
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t) ? null : AccountFieldError.emailInvalid;
}

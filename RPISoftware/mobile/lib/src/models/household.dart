/// Household invites: a resident invites someone with their own Canary
/// account to join their apartment by a one-time link.
library;

DateTime? _ts(Object? v) => v is String ? DateTime.tryParse(v) : null;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

/// `POST /me/household/invites` answer. [code] / [url] exist only here.
class CreatedInvite {
  const CreatedInvite({
    required this.id,
    required this.code,
    required this.url,
    required this.unitId,
    this.appUrl,
    this.unitLabel,
    this.careProfileId,
    this.expiresTs,
  });
  final String id;
  final String code;

  /// `{hub}/join/{code}` (opens the app or the web app).
  final String url;

  /// `canary://join/{code}`.
  final String? appUrl;
  final String unitId;
  final String? unitLabel;
  final String? careProfileId;
  final DateTime? expiresTs;

  factory CreatedInvite.fromJson(Map<String, dynamic> j) => CreatedInvite(
        id: '${j['id']}',
        code: _str(j['code']) ?? '',
        url: _str(j['url']) ?? '',
        appUrl: _str(j['app_url']),
        unitId: _str(j['unit_id']) ?? '',
        unitLabel: _str(j['unit_label']),
        careProfileId: _str(j['care_profile_id']),
        expiresTs: _ts(j['expires_ts']),
      );
}

/// A pending invite (`GET /me/household/invites`); no code.
class PendingInvite {
  const PendingInvite({required this.id, required this.unitId, this.unitLabel, this.careProfileName, this.createdTs, this.expiresTs});
  final String id;
  final String unitId;
  final String? unitLabel;
  final String? careProfileName;
  final DateTime? createdTs;
  final DateTime? expiresTs;

  factory PendingInvite.fromJson(Map<String, dynamic> j) => PendingInvite(
        id: '${j['id']}',
        unitId: _str(j['unit_id']) ?? '',
        unitLabel: _str(j['unit_label']),
        careProfileName: _str(j['care_profile_name']),
        createdTs: _ts(j['created_ts']),
        expiresTs: _ts(j['expires_ts']),
      );
}

/// `GET /household/invites/{code}`: what the invitee sees before accepting.
class InvitePreview {
  const InvitePreview({
    this.buildingName,
    this.unitLabel,
    this.floorLabel,
    this.inviterName,
    this.hasCareProfile = false,
    this.careProfileName,
    this.expiresTs,
  });
  final String? buildingName;
  final String? unitLabel;
  final String? floorLabel;
  final String? inviterName;
  final bool hasCareProfile;
  final String? careProfileName;
  final DateTime? expiresTs;

  factory InvitePreview.fromJson(Map<String, dynamic> j) => InvitePreview(
        buildingName: _str(j['building_name']),
        unitLabel: _str(j['unit_label']),
        floorLabel: _str(j['floor_label']),
        inviterName: _str(j['inviter_name']),
        hasCareProfile: j['has_care_profile'] == true,
        careProfileName: _str(j['care_profile_name']),
        expiresTs: _ts(j['expires_ts']),
      );
}

/// `POST /household/invites/{code}/accept` answer.
class AcceptedInvite {
  const AcceptedInvite({required this.unitId, this.unitLabel, this.buildingId, this.careProfileId});
  final String unitId;
  final String? unitLabel;
  final String? buildingId;
  final String? careProfileId;

  factory AcceptedInvite.fromJson(Map<String, dynamic> j) => AcceptedInvite(
        unitId: _str(j['unit_id']) ?? '',
        unitLabel: _str(j['unit_label']),
        buildingId: _str(j['building_id']),
        careProfileId: _str(j['care_profile_id']),
      );
}

class HouseholdMember {
  const HouseholdMember({required this.userId, required this.displayName, this.isMe = false, this.since});
  final String userId;
  final String displayName;
  final bool isMe;
  final DateTime? since;
}

/// `GET /me/household` item: one of the caller's units and who lives there.
class HouseholdUnit {
  const HouseholdUnit({required this.unitId, this.unitLabel, this.members = const []});
  final String unitId;
  final String? unitLabel;
  final List<HouseholdMember> members;

  factory HouseholdUnit.fromJson(Map<String, dynamic> j) {
    final raw = j['members'];
    return HouseholdUnit(
      unitId: _str(j['unit_id']) ?? '',
      unitLabel: _str(j['unit_label']),
      members: [
        if (raw is List)
          for (final m in raw.whereType<Map<String, dynamic>>())
            HouseholdMember(
              userId: '${m['user_id']}',
              displayName: _str(m['display_name']) ?? '—',
              isMe: m['is_me'] == true,
              since: _ts(m['since']),
            ),
      ],
    );
  }
}

final _codePattern = RegExp(r'^[A-Za-z0-9_-]{4,64}$');

/// The invite code in what the user pasted: the bare code, `canary://join/X`,
/// `https://hub/join/X` (also `#/join/X` web links), with or without spaces,
/// query or trailing slash. null when nothing code-like is there.
String? extractInviteCode(String input) {
  final t = input.trim();
  if (t.isEmpty) return null;
  final m = RegExp(r'join/([A-Za-z0-9_-]{4,64})').firstMatch(t);
  if (m != null) return m.group(1);
  return _codePattern.hasMatch(t) ? t : null;
}

/// The invite code a deep link routes to, or null. Flutter's deep linking
/// gives `/join/X` for http(s) links (and the web app) and `/X` for
/// `canary://join/X` (the host is not part of the path).
String? inviteCodeFromRoute(String? route) {
  if (route == null) return null;
  final uri = Uri.tryParse(route);
  final segments = (uri?.pathSegments ?? const <String>[]).where((s) => s.isNotEmpty).toList();
  if (segments.length == 2 && segments.first == 'join' && _codePattern.hasMatch(segments[1])) return segments[1];
  if (segments.length == 1 && segments.first != 'join' && _codePattern.hasMatch(segments.first)) {
    return segments.first;
  }
  return null;
}

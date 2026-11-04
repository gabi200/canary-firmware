/// `GET /api/v1/mode`: the hub-wide demo / real switch every screen follows.
class HubMode {
  const HubMode({required this.mode, required this.buildingId, this.liveAlarm = false});

  /// "demo" or "real".
  final String mode;

  /// The building the mode shows: bld_007 (demo) or bld_live (real).
  final String buildingId;

  /// An incident is open in the real building, whatever the mode.
  final bool liveAlarm;

  bool get isDemo => mode == 'demo';

  factory HubMode.fromJson(Map<String, dynamic> j) => HubMode(
        mode: j['mode'] as String,
        buildingId: j['building_id'] as String,
        liveAlarm: j['live_alarm'] == true,
      );
}

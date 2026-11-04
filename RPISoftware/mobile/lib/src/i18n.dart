import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import 'logic/relative_location.dart';
import 'logic/sensor_series.dart';
import 'models/care_profile.dart';
import 'models/check_in.dart';
import 'models/incident.dart';
import 'models/node_command.dart';
import 'services/api_client.dart';

export '../l10n/app_localizations.dart';

/// Languages the app ships (lib/l10n/app_<code>.arb).
const supportedLanguageCodes = {'en', 'ro'};

extension BuildContextL10n on BuildContext {
  /// Strings for the active app language (set on the MaterialApp, see main.dart).
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// Maps backend tokens (hazard types, incident states, analysis levels, roles...)
/// to text in the active language. Unknown tokens fall back to the raw token so
/// a newer backend never renders as blank. Building data (zone labels, waypoint
/// text, names) is shown as-is and never passes through here.
extension AppLocalizationsLabels on AppLocalizations {
  String classificationName(String? label) => switch (label) {
        'smouldering_fire' => classificationSmouldering,
        'flaming_fire' => classificationFlaming,
        'gas_leak' => classificationGas,
        'steam' => classificationSteam,
        'cooking' => classificationCooking,
        'aerosol' => classificationAerosol,
        'normal' => classificationNormal,
        'unknown' => classificationUnknown,
        _ => classificationUnavailable,
      };

  String hazardName(String hazardType) => switch (hazardType) {
        'combustible_gas' => hazardGasLeak,
        'co' => hazardCarbonMonoxide,
        'water_leak' => hazardWaterLeak,
        'particulate' => hazardSmoke,
        _ => hazardType,
      };

  /// Incident states, hub analysis levels and node states as shown in pills.
  String statusLabel(String token) => switch (token) {
        'normal' => stateNormal,
        'detection' => stateDetection,
        'verification' => stateVerification,
        'alarm' => stateAlarm,
        'escalation' => stateEscalation,
        'evacuation' => stateEvacuation,
        'resolution' => stateResolution,
        'false_alarm' => stateFalseAlarm,
        'ok' => levelOk,
        'attention' => levelAttention,
        'danger' => levelDanger,
        'unknown' => levelUnknown,
        'offline' => statusOffline,
        'stale' => statusNoData,
        _ => token.replaceAll('_', ' '),
      };

  /// One line saying where the danger is from the resident's point of view.
  String hazardWhereText(HazardWhere where) {
    final detail = where.detail ?? '';
    return switch (where.place) {
      HazardPlace.home => whereHome(detail),
      HazardPlace.myFloor => whereMyFloor(detail),
      HazardPlace.myFloorCommon => whereMyFloorCommon(detail),
      HazardPlace.otherFloor => whereOtherFloor(detail),
      HazardPlace.commonArea => whereCommonArea(detail),
      HazardPlace.building => whereBuilding(detail),
      HazardPlace.unknown => whereUnknown,
    };
  }

  /// The "Unde ești acum?" answer as a button / summary word.
  String whereNowLabel(ResidentLocation where) => switch (where) {
        ResidentLocation.home => whereNowHome,
        ResidentLocation.building => whereNowBuilding,
        ResidentLocation.outside => whereNowOutside,
      };

  /// Next steps for an answer; [assemblyPoint] names where to go once outside.
  String whereAdviceText(WhereAdvice advice, {String? assemblyPoint}) => switch (advice) {
        WhereAdvice.leaveHomeNow => adviceLeaveHomeNow,
        WhereAdvice.leaveHome => adviceLeaveHome,
        WhereAdvice.getReady => adviceGetReady,
        WhereAdvice.leaveBuilding => adviceLeaveBuilding,
        WhereAdvice.stayOut =>
          assemblyPoint == null || assemblyPoint.isEmpty ? adviceStayOutNoPoint : adviceStayOut(assemblyPoint),
      };

  String roleName(String role) => switch (role) {
        'resident' => roleResident,
        'hoa_manager' => roleManager,
        'dispatcher_external' => roleDispatcher,
        'system_admin' => roleAdmin,
        _ => role,
      };

  String checkInLabel(CheckInStatus status) => switch (status) {
        CheckInStatus.safeOutside => imOutAndSafe,
        CheckInStatus.safeInside => imSafeStillInside,
        CheckInStatus.needsHelp => iNeedHelp,
      };

  /// Fallback for the overall / per-sensor headline when the hub sends none.
  String analysisStatus(String status) => switch (status) {
        'ok' => allClear,
        'attention' => statusNeedsAttention,
        'danger' => statusDanger,
        _ => statusUnknown,
      };

  String sensorKind(String kind) => switch (kind) {
        'air' => kindAir,
        'water' => kindWater,
        _ => kindSensor,
      };

  /// Fallback indicator label (HARDWARE.md §3) when the hub sends none.
  String indicatorLabel(String key) => switch (key) {
        'air_quality' => indicatorAirQuality,
        'co' => indicatorCo,
        'gas' => indicatorGas,
        'comfort' => indicatorComfort,
        'occupancy' => indicatorOccupancy,
        'leak' => indicatorLeak,
        'valve' => indicatorValve,
        'health' => kindSensor,
        _ => key,
      };

  String? trendLabel(String? trend) => switch (trend) {
        'rising' => trendRising,
        'falling' => trendFalling,
        'stable' => trendStable,
        _ => trend,
      };

  /// Title + body of the local notification for an alarming incident. Built on
  /// the device (the WebSocket frame's own title/body are English-only, shared by
  /// every client of the building) and mirrors backend notify/service.py.
  ({String title, String body}) incidentAlert(Incident incident) {
    final hazard = hazardName(incident.hazardType);
    return switch (incident.state) {
      'evacuation' => (title: notifEvacuateTitle(hazard), body: notifEvacuateBody),
      'escalation' => (title: notifEscalatedTitle(hazard), body: notifEscalatedBody),
      'alarm' => (
          title: notifAlarmTitle(hazard),
          body: switch (incident.hazardType) {
            'water_leak' => notifAlarmBodyWaterLeak,
            'particulate' => notifAlarmBodySmoke,
            _ => notifAlarmBody(hazard),
          },
        ),
      _ => (title: notifAlertTitle(hazard), body: notifOpenForGuidance),
    };
  }

  /// Wall-clock time in the active locale: "21:40" today, else "8 oct. 21:40".
  String clockTime(DateTime ts, {DateTime? now}) {
    final local = ts.toLocal();
    final today = (now ?? DateTime.now()).toLocal();
    final sameDay =
        local.year == today.year && local.month == today.month && local.day == today.day;
    return (sameDay ? DateFormat.Hm(localeName) : DateFormat.MMMd(localeName).add_Hm())
        .format(local);
  }

  /// "just now" / "5 min ago" / "3 h ago", then a [clockTime] after a day.
  String timeAgo(DateTime ts, {DateTime? now}) {
    final d = (now ?? DateTime.now()).difference(ts);
    if (d.inMinutes < 1) return timeJustNow;
    if (d.inHours < 1) return minutesAgo(d.inMinutes);
    if (d.inDays < 1) return hoursAgo(d.inHours);
    return clockTime(ts, now: now);
  }

  /// Why a request failed, for the UI: the server's own `detail` when it sent
  /// one (shown as sent), else a localized description.
  String errorReason(Object error) {
    if (error is ApiException) {
      final code = error.statusCode;
      if (code == null) return serverUnreachable;
      return error.detail ?? serverError(code);
    }
    return error.toString();
  }

  /// A device's answer code (air_sensor / water_sensor `MqttService.cpp`) in
  /// plain words; an unknown code is shown as sent, underscores as spaces.
  String? commandDetail(String? code) => switch (code) {
        null || '' => null,
        'self_test' => detailSelfTest,
        'silenced' => detailSilenced,
        'self_test_busy' => detailSelfTestBusy,
        'alarm_inactive' => detailAlarmInactive,
        'open' => detailOpen,
        'closed' => detailClosed,
        'busy' => detailBusy,
        'invalid_command' => detailInvalidCommand,
        'sensor_wet' => detailSensorWet,
        'sensor_uninitialized' => detailSensorUninitialized,
        'ota_active' => detailOtaActive,
        'command_rejected' => detailCommandRejected,
        'persistence_failed' => detailPersistenceFailed,
        _ => code.replaceAll('_', ' '),
      };

  /// Short name of a command for the status row ("Test alarmă").
  String commandName(NodeCommandType command) => switch (command) {
        NodeCommandType.test => commandTest,
        NodeCommandType.silence => commandSilence,
        NodeCommandType.open => commandOpen,
        NodeCommandType.close => commandClose,
      };

  /// Why the hub would not send a command, by HTTP status (null: no answer).
  String commandFailure(int? status, String? detail) => switch (status) {
        null => serverUnreachable,
        409 => cmdErrOffline,
        429 => cmdErrTooSoon,
        404 => cmdErrNotYours,
        422 => cmdErrInvalid,
        403 => cmdErrForbidden,
        503 => cmdErrHubOffline, // the hub's MQTT broker is down
        _ => detail ?? serverError(status),
      };

  /// "Ultimul test: reușit · acum 2 min", or "Netestat" without a command.
  /// Other commands are named, so a refused "silence" (no alarm to silence)
  /// never reads as a failed test: "Oprire alarmă: respins · chiar acum".
  /// [short]: "Test: reușit · acum 2 min", for the small sketch cells.
  String lastTestText(NodeCommand? command, {DateTime? now, bool short = false}) {
    if (command == null) return lastTestNone;
    final result = switch (command.status) {
      CommandStatus.accepted => lastTestAccepted,
      CommandStatus.rejected => lastTestRejected,
      CommandStatus.timeout => lastTestTimeout,
      CommandStatus.sent => lastTestSent,
    };
    final ts = command.ts;
    final when = ts == null ? null : timeAgo(ts, now: now);
    final type = command.type;
    if (type == null || type == NodeCommandType.test) {
      if (when == null) return lastTestNoTime(result);
      return short ? lastTestShort(result, when) : lastTest(result, when);
    }
    final name = commandName(type);
    return when == null ? lastOtherCommandNoTime(name, result) : lastOtherCommand(name, result, when);
  }

  String careNeed(CareNeed need) => switch (need) {
        CareNeed.reducedMobility => needReducedMobility,
        CareNeed.wheelchair => needWheelchair,
        CareNeed.bedridden => needBedridden,
        CareNeed.hearingImpaired => needHearingImpaired,
        CareNeed.visuallyImpaired => needVisuallyImpaired,
        CareNeed.medicalDevice => needMedicalDevice,
        CareNeed.youngChild => needYoungChild,
        CareNeed.pet => needPet,
      };

  /// Household check-in button text for a status.
  String householdStatus(CheckInStatus status) => switch (status) {
        CheckInStatus.safeOutside => householdOut,
        CheckInStatus.safeInside => householdInside,
        CheckInStatus.needsHelp => householdNeedsHelp,
      };

  /// Why saving / deleting a care profile failed, in plain words.
  String careError(Object error) {
    if (error is ApiException) {
      switch (error.statusCode) {
        case 503:
          return careNotActive;
        case 409:
          return careSelfExists;
        case 404:
          return careUnitNotYours;
        case 422:
          return careInvalid;
      }
    }
    return errorReason(error);
  }

  /// Why an invite action failed, in plain words.
  String inviteError(Object error) {
    if (error is ApiException) {
      switch (error.statusCode) {
        case 404:
          return inviteInvalid;
        case 403:
          return inviteStaff;
        case 409:
          return inviteConflict;
        case 422:
          return inviteNeedsConsent;
        case 429:
          return inviteTooMany;
      }
    }
    return errorReason(error);
  }

  /// Locale-aware integer, e.g. 1,234 (en) / 1.234 (ro).
  String count(num value) => NumberFormat.decimalPattern(localeName).format(value);

  /// Locale-aware fixed decimals, e.g. 22.4 (en) / 22,4 (ro).
  String decimal(num value, {int digits = 1}) =>
      NumberFormat.decimalPatternDigits(locale: localeName, decimalDigits: digits).format(value);

  String verdictWord(Verdict v) => switch (v) {
        Verdict.good => verdictGood,
        Verdict.moderate => verdictModerate,
        Verdict.poor => verdictPoor,
        Verdict.danger => verdictDanger,
        Verdict.safe => verdictSafe,
        Verdict.elevated => verdictElevated,
        Verdict.normal => verdictNormal,
        Verdict.cool => verdictCool,
        Verdict.comfortable => verdictComfortable,
        Verdict.warm => verdictWarm,
        Verdict.dryAir => verdictDryAir,
        Verdict.humidityOk => verdictHumidityOk,
        Verdict.humid => verdictHumid,
        Verdict.dry => verdictDry,
        Verdict.leak => verdictLeak,
      };

  /// "in the last hour / 6 hours / 24 hours / 7 days" for a history window.
  String inWindow(int minutes) => minutes <= 60
      ? inLastHour
      : minutes <= 360
          ? inLast6h
          : minutes <= 1440
              ? inLast24h
              : inLast7d;

  /// Full name of a history window ("Last hour", "6 hours", "24 hours", "7 days").
  String windowName(int minutes) => minutes <= 60
      ? rangeHour
      : minutes <= 360
          ? range6h
          : minutes <= 1440
              ? range24h
              : range7d;

  /// Short toggle label ("1h", "6h", "24h", "7d" / "7z").
  String windowShort(int minutes) => minutes <= 60
      ? rangeHourShort
      : minutes <= 360
          ? range6hShort
          : minutes <= 1440
              ? range24hShort
              : range7dShort;
}

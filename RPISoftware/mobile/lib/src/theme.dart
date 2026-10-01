import 'package:flutter/material.dart';

/// Hazard-state color language shared across the UI (normal / warning / alarm / evacuation).
class HazardColors {
  static const normal = Color(0xFF2E7D32); // green
  static const warning = Color(0xFFF9A825); // amber
  static const alarm = Color(0xFFD32F2F); // red
  static const evacuation = Color(0xFFB71C1C); // deep red
  static const info = Color(0xFF1565C0); // blue
  static const unknown = Color(0xFF757575); // grey — no data / offline
  static const onHazard = Colors.white;
  static const onHazardMuted = Colors.white70;
  static const surface = Colors.white;
  static const text = Color(0xFF202124);
  static const muted = Color(0xFF5F6368);
  static const onSurfaceMuted = Color(0x8A000000);
  static const onSurfaceDisabled = Color(0x73000000);
  static const onSurfaceFaint = Color(0x61000000);
  static const divider = Color(0xFFDADCE0);
  static const warnBg = Color(0xFFFFE082);
  static const warnFg = Color(0xFF292100);
  static const routeLine = normal;
  static const start = info;
  static const evacuationPulse = alarm;
  static const evacuationBorder = warning;

  /// Hub analysis level or status (HARDWARE.md §3): ok | attention | danger | unknown.
  static Color forLevel(String level) {
    switch (level) {
      case 'danger':
        return alarm;
      case 'attention':
        return warning;
      case 'ok':
        return normal;
      default:
        return unknown;
    }
  }

  static Color forState(String state) {
    switch (state) {
      case 'evacuation':
        return evacuation;
      case 'alarm':
      case 'escalation':
        return alarm;
      case 'detection':
      case 'verification':
        return warning;
      case 'resolution':
      case 'false_alarm':
      case 'normal':
        return normal;
      default:
        return info;
    }
  }
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1565C0),
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    appBarTheme: const AppBarTheme(centerTitle: true),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

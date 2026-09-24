import 'package:flutter/material.dart';

/// Hazard-state color language shared across the UI (normal / warning / alarm / evacuation).
class HazardColors {
  static const normal = Color(0xFF2E7D32); // green
  static const warning = Color(0xFFF9A825); // amber
  static const alarm = Color(0xFFD32F2F); // red
  static const evacuation = Color(0xFFB71C1C); // deep red
  static const info = Color(0xFF1565C0); // blue
  static const unknown = Color(0xFF757575); // grey — no data / offline

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

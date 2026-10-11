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
  static const divider = Color(0xFFDADCE0);
  static const warnBg = Color(0xFFFFE082);
  static const warnFg = Color(0xFF292100);
  static const routeLine = normal;
  static const start = info;

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

/// Neutral colours that change with light / dark mode, plus [ink] for status
/// colours drawn as text or icons on the app's surfaces. Hazard fills (red /
/// amber / green banners with white text) stay the same in both modes.
@immutable
class CanaryPalette extends ThemeExtension<CanaryPalette> {
  const CanaryPalette({
    required this.dark,
    required this.surface,
    required this.text,
    required this.muted,
    required this.faint,
    required this.divider,
    required this.tile,
    required this.tileBorder,
    required this.chip,
  });

  static const light = CanaryPalette(
    dark: false,
    surface: Colors.white,
    text: HazardColors.text,
    muted: Colors.black54,
    faint: Colors.black38,
    divider: HazardColors.divider,
    tile: Color(0xFFF5F6F8),
    tileBorder: Color(0xFFE3E5E8),
    chip: Color(0xFFE8EAED),
  );

  static const darkPalette = CanaryPalette(
    dark: true,
    surface: Color(0xFF1C1F24),
    text: Color(0xFFE8EAED),
    muted: Color(0xFFB4B9C0),
    faint: Color(0xFF8A9099),
    divider: Color(0xFF3C4148),
    tile: Color(0xFF262A30),
    tileBorder: Color(0xFF3A3F47),
    chip: Color(0xFF3A3F47),
  );

  final bool dark;

  /// Cards, sheets and the alarm screen's body.
  final Color surface;
  final Color text;

  /// Secondary text (was black54).
  final Color muted;

  /// Hints, chevrons, disabled (was black38).
  final Color faint;
  final Color divider;

  /// Reading tiles and empty-state boxes.
  final Color tile;
  final Color tileBorder;

  /// Small count badges.
  final Color chip;

  /// A status colour as text or an icon on [surface]: as is in light mode,
  /// lighter in dark mode so green / amber / red stay readable.
  Color ink(Color status) => dark ? Color.lerp(status, Colors.white, 0.45)! : status;

  /// [status] washed over [surface], for tinted cards and tiles.
  Color tint(Color status, [int alpha = 30]) =>
      Color.alphaBlend(status.withAlpha(dark ? alpha + 24 : alpha), surface);

  @override
  CanaryPalette copyWith() => this;

  @override
  CanaryPalette lerp(CanaryPalette? other, double t) => other == null || t < 0.5 ? this : other;
}

extension CanaryPaletteX on BuildContext {
  /// The palette of the active theme (light when a test pumps no theme).
  CanaryPalette get palette => Theme.of(this).extension<CanaryPalette>() ?? CanaryPalette.light;
}

ThemeData buildTheme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;
  final palette = dark ? CanaryPalette.darkPalette : CanaryPalette.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1565C0),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: dark ? scheme.copyWith(surface: const Color(0xFF121418)) : scheme,
    appBarTheme: const AppBarTheme(centerTitle: true),
    cardTheme: dark ? CardThemeData(color: palette.surface) : null,
    dividerColor: palette.divider,
    // White text reads on the app's green / red snackbars in both modes; the
    // plain ones are dark grey in dark mode (not the light inverse surface).
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? const Color(0xFF3A3F47) : null,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
    ),
    extensions: [palette],
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

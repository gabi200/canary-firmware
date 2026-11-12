import 'package:flutter/material.dart';

/// Hazard-state colours shared across the UI (normal / warning / alarm / evacuation).
///
/// These are the console's solid state steps (DESIGN.md, "Secondary (state)"): dots,
/// fills and borders. Text in a state colour goes through [CanaryPalette.ink], which
/// swaps a solid for its theme-tuned text step.
class HazardColors {
  static const normal = Color(0xFF2FA84F); // Safe Green
  static const warning = Color(0xFFD4A11E); // Attention Amber
  static const alarm = Color(0xFFD93A40); // Alarm Red
  static const evacuation = Color(0xFFA8231F); // Evacuation Deep Red: evacuation only
  static const info = Color(0xFF3B7CF0); // Action Blue: action and selection, never hazard
  static const unknown = Color(0xFF8B94A1); // Muted: no data / offline

  /// The incident banner's alarm fill (white text at 5:1 or better).
  static const alarmFill = Color(0xFFCC363F);
  static const onHazard = Colors.white;
  static const onHazardMuted = Color(0xE6FFFFFF);

  /// Status text on red banners (on-alarm ok / warn).
  static const onAlarmOk = Color(0xFF6FDC8F);
  static const onAlarmWarn = Color(0xFFF0C458);

  /// Light-theme neutrals, for the few places drawn outside a themed context.
  static const surface = Colors.white;
  static const text = Color(0xFF14171C);
  static const muted = Color(0xFF5D6673);
  static const divider = Color(0xFFE2E5EA);

  /// Amber fill and its ink (detection banners, warning snackbars).
  static const warnBg = warning;
  static const warnFg = Color(0xFF1C1503);
  static const routeLine = normal;
  static const start = info;

  /// Hazard tape: the 4px strip on the active-evacuation banner only.
  static const tapeBlack = Color(0xFF111111);
  static const tapeAmber = Color(0xFFE0AA1C);

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

  /// Banner fill for an incident state: amber for detection / verification, deep red for
  /// evacuation, the alarm fill for alarm, escalation and anything unknown.
  static Color bannerFill(String state) => switch (state) {
        'evacuation' => evacuation,
        'detection' || 'verification' => warning,
        'resolution' || 'false_alarm' || 'normal' => normal,
        _ => alarmFill,
      };

  /// Ink on [bannerFill]: dark on amber, white elsewhere.
  static Color onBanner(String state) =>
      (state == 'detection' || state == 'verification') ? warnFg : onHazard;
}

/// Radii of the console (DESIGN.md, Shapes): 8 for containers, 6 for controls,
/// 4 for small tags, 12 for overlays.
class CanaryRadius {
  static const double container = 8;
  static const double control = 6;
  static const double tag = 4;
  static const double overlay = 12;
}

/// The console's neutral surfaces and state text steps, per theme (DESIGN.md and the
/// `.impeccable/design.json` sidecar). The older names ([surface], [tile], [chip] …)
/// map onto the console's three surface steps so existing screens follow.
@immutable
class CanaryPalette extends ThemeExtension<CanaryPalette> {
  const CanaryPalette({
    required this.dark,
    required this.ground,
    required this.panel,
    required this.raised,
    required this.well,
    required this.hairline,
    required this.hairlineStrong,
    required this.text,
    required this.textSecondary,
    required this.muted,
    required this.accent,
    required this.accentText,
    required this.safeText,
    required this.attentionText,
    required this.alarmText,
    required this.wordmarkDot,
  });

  static const light = CanaryPalette(
    dark: false,
    ground: Color(0xFFF5F6F8),
    panel: Colors.white,
    raised: Color(0xFFF1F3F5),
    well: Color(0xFFF7F8FA),
    hairline: Color(0xFFE2E5EA),
    hairlineStrong: Color(0xFFCBD0D8),
    text: Color(0xFF14171C),
    textSecondary: Color(0xFF3C434E),
    muted: Color(0xFF5D6673),
    accent: Color(0xFF2563EB),
    accentText: Color(0xFF1D55CF),
    safeText: Color(0xFF17723A),
    attentionText: Color(0xFF875800),
    alarmText: Color(0xFFC0262C),
    wordmarkDot: Color(0xFFD99A00),
  );

  static const darkPalette = CanaryPalette(
    dark: true,
    ground: Color(0xFF0C0E11),
    panel: Color(0xFF13161A),
    raised: Color(0xFF1A1E24),
    well: Color(0xFF0F1215),
    hairline: Color(0xFF23282F),
    hairlineStrong: Color(0xFF323943),
    text: Color(0xFFE8EAED),
    textSecondary: Color(0xFFB9BFC8),
    muted: Color(0xFF8B94A1),
    accent: Color(0xFF3B7CF0),
    accentText: Color(0xFF7AA9FF),
    safeText: Color(0xFF56C878),
    attentionText: Color(0xFFE3B54A),
    alarmText: Color(0xFFFF7B72),
    wordmarkDot: Color(0xFFF2C417),
  );

  final bool dark;
  final Color ground;
  final Color panel;
  final Color raised;
  final Color well;
  final Color hairline;
  final Color hairlineStrong;
  final Color text;
  final Color textSecondary;
  final Color muted;
  final Color accent;
  final Color accentText;
  final Color safeText;
  final Color attentionText;
  final Color alarmText;
  final Color wordmarkDot;

  /// Cards, sheets and the alarm screen's body.
  Color get surface => panel;

  /// Hints, chevrons, disabled.
  Color get faint => muted;
  Color get divider => hairline;

  /// Reading tiles and empty-state boxes (inset surfaces).
  Color get tile => well;
  Color get tileBorder => hairline;

  /// Small count badges.
  Color get chip => raised;

  /// A state colour as text or an icon on a panel: the solid's theme-tuned text step.
  Color ink(Color status) {
    if (status == HazardColors.normal) return safeText;
    if (status == HazardColors.warning) return attentionText;
    if (status == HazardColors.alarm ||
        status == HazardColors.alarmFill ||
        status == HazardColors.evacuation) {
      return alarmText;
    }
    if (status == HazardColors.info) return accentText;
    if (status == HazardColors.unknown) return muted;
    return dark ? Color.lerp(status, Colors.white, 0.4)! : status;
  }

  /// [status] as a soft tint over the panel, for state cards and pills.
  Color tint(Color status, [int alpha = 22]) =>
      Color.alphaBlend(status.withAlpha(dark ? alpha + 6 : alpha), panel);

  /// The state border of a tinted card.
  Color stateBorder(Color status) => status.withAlpha(dark ? 120 : 140);

  @override
  CanaryPalette copyWith() => this;

  @override
  CanaryPalette lerp(CanaryPalette? other, double t) => other == null || t < 0.5 ? this : other;
}

extension CanaryPaletteX on BuildContext {
  /// The palette of the active theme (light when a test pumps no theme).
  CanaryPalette get palette => Theme.of(this).extension<CanaryPalette>() ?? CanaryPalette.light;
}

const _font = 'Inter';
const _tabular = [FontFeature.tabularFigures()];

TextTheme _textTheme(CanaryPalette p) {
  TextStyle s(double size, FontWeight w, double height, [double track = 0, Color? c]) => TextStyle(
        fontFamily: _font,
        fontSize: size,
        fontWeight: w,
        height: height,
        letterSpacing: size * track,
        color: c ?? p.text,
        fontFeatures: _tabular,
      );
  return TextTheme(
    displayLarge: s(40, FontWeight.w600, 1, -0.03),
    displayMedium: s(32, FontWeight.w600, 1.1, -0.025),
    displaySmall: s(28, FontWeight.w600, 1.15, -0.02),
    headlineLarge: s(28, FontWeight.w600, 1.15, -0.02),
    headlineMedium: s(24, FontWeight.w600, 1.15, -0.02),
    headlineSmall: s(20, FontWeight.w600, 1.2, -0.015),
    titleLarge: s(18, FontWeight.w600, 1.3, -0.011),
    titleMedium: s(15, FontWeight.w600, 1.4, -0.011),
    titleSmall: s(14, FontWeight.w600, 1.45, -0.011),
    bodyLarge: s(15, FontWeight.w400, 1.45),
    bodyMedium: s(14, FontWeight.w400, 1.45),
    bodySmall: s(13, FontWeight.w400, 1.45, 0, p.textSecondary),
    labelLarge: s(14, FontWeight.w500, 1.25),
    labelMedium: s(12, FontWeight.w500, 1.25, 0, p.muted),
    labelSmall: s(11, FontWeight.w500, 1.25, 0, p.muted),
  );
}

ThemeData buildTheme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;
  final p = dark ? CanaryPalette.darkPalette : CanaryPalette.light;
  final text = _textTheme(p);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: Colors.white,
    primaryContainer: p.tint(p.accent, 40),
    onPrimaryContainer: p.accentText,
    secondary: p.accent,
    onSecondary: Colors.white,
    secondaryContainer: p.raised,
    onSecondaryContainer: p.text,
    tertiary: p.accent,
    onTertiary: Colors.white,
    error: HazardColors.alarm,
    onError: Colors.white,
    errorContainer: p.tint(HazardColors.alarm, 40),
    onErrorContainer: p.alarmText,
    surface: p.ground,
    onSurface: p.text,
    onSurfaceVariant: p.muted,
    surfaceContainerLowest: p.well,
    surfaceContainerLow: p.panel,
    surfaceContainer: p.panel,
    surfaceContainerHigh: p.raised,
    surfaceContainerHighest: p.raised,
    outline: p.hairlineStrong,
    outlineVariant: p.hairline,
    shadow: Colors.black,
    scrim: dark ? const Color(0xAD040609) : const Color(0x6B14171C),
    inverseSurface: dark ? const Color(0xFFE8EAED) : const Color(0xFF1A1E24),
    onInverseSurface: dark ? const Color(0xFF14171C) : const Color(0xFFE8EAED),
    inversePrimary: p.accentText,
    surfaceTint: Colors.transparent,
  );
  final control = RoundedRectangleBorder(borderRadius: BorderRadius.circular(CanaryRadius.control));
  final container = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(CanaryRadius.container),
    side: BorderSide(color: p.hairline),
  );
  final buttonText = text.labelLarge!.copyWith(fontWeight: FontWeight.w600);
  const buttonSize = Size(48, 44);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: _font,
    textTheme: text,
    scaffoldBackgroundColor: p.ground,
    canvasColor: p.ground,
    dividerColor: p.hairline,
    splashFactory: InkSparkle.constantTurbulenceSeedSplashFactory,
    extensions: [p],
    appBarTheme: AppBarTheme(
      backgroundColor: p.ground,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 52,
      titleSpacing: 16,
      titleTextStyle: text.titleMedium,
      shape: Border(bottom: BorderSide(color: p.hairline)),
      iconTheme: IconThemeData(color: p.textSecondary, size: 22),
      actionsIconTheme: IconThemeData(color: p.textSecondary, size: 22),
    ),
    cardTheme: CardThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: container,
    ),
    dividerTheme: DividerThemeData(color: p.hairline, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: p.textSecondary,
      textColor: p.text,
      titleTextStyle: text.bodyLarge!.copyWith(fontWeight: FontWeight.w500),
      subtitleTextStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      minVerticalPadding: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CanaryRadius.container)),
    ),
    iconTheme: IconThemeData(color: p.textSecondary, size: 22),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.raised,
        disabledForegroundColor: p.muted,
        minimumSize: const Size.fromHeight(48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: control,
        textStyle: buttonText.copyWith(fontSize: 16),
        elevation: 0,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.panel,
        foregroundColor: p.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        minimumSize: buttonSize,
        shape: control.copyWith(side: BorderSide(color: p.hairlineStrong)),
        textStyle: buttonText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        backgroundColor: p.panel,
        disabledForegroundColor: p.muted,
        minimumSize: buttonSize,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        side: BorderSide(color: p.hairlineStrong),
        shape: control,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accentText,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: control,
        textStyle: buttonText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.textSecondary, shape: control),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: p.well,
        foregroundColor: p.textSecondary,
        selectedBackgroundColor: p.tint(p.accent, 46),
        selectedForegroundColor: p.accentText,
        side: BorderSide(color: p.hairlineStrong),
        shape: control,
        textStyle: text.labelLarge,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.panel,
      selectedColor: p.tint(p.accent, 40),
      disabledColor: p.raised,
      side: BorderSide(color: p.hairlineStrong),
      shape: control,
      labelStyle: text.labelLarge!.copyWith(fontSize: 13),
      secondaryLabelStyle: text.labelLarge!.copyWith(fontSize: 13, color: p.accentText),
      checkmarkColor: p.accentText,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.panel,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      labelStyle: text.bodyMedium!.copyWith(color: p.textSecondary, fontWeight: FontWeight.w500),
      floatingLabelStyle: text.bodyMedium!.copyWith(color: p.accentText, fontWeight: FontWeight.w500),
      hintStyle: text.bodyMedium!.copyWith(color: p.muted),
      helperStyle: text.labelMedium,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CanaryRadius.control), borderSide: BorderSide(color: p.hairlineStrong)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CanaryRadius.control), borderSide: BorderSide(color: p.hairlineStrong)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CanaryRadius.control), borderSide: BorderSide(color: p.accent, width: 1.5)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CanaryRadius.control),
          borderSide: const BorderSide(color: HazardColors.alarm)),
      focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CanaryRadius.control),
          borderSide: const BorderSide(color: HazardColors.alarm, width: 1.5)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.ground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      indicatorColor: p.raised,
      indicatorShape: control,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => text.labelMedium!.copyWith(
            color: s.contains(WidgetState.selected) ? p.text : p.muted,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            size: 22,
            color: s.contains(WidgetState.selected) ? p.accentText : p.muted,
          )),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : p.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.raised),
      trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.accent : p.hairlineStrong),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.muted),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : Colors.transparent),
      side: BorderSide(color: p.hairlineStrong, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CanaryRadius.tag)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.raised,
      circularTrackColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: p.panel,
      showDragHandle: true,
      dragHandleColor: p.hairlineStrong,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(CanaryRadius.overlay))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CanaryRadius.overlay),
        side: BorderSide(color: p.hairline),
      ),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium!.copyWith(color: p.textSecondary),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CanaryRadius.container),
        side: BorderSide(color: p.hairlineStrong),
      ),
      textStyle: text.bodyMedium,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(CanaryRadius.control),
        border: Border.all(color: p.hairlineStrong),
      ),
      textStyle: text.bodySmall!.copyWith(color: p.text),
    ),
    // Plain snackbars sit on the raised step; the app's green / red / amber ones set
    // their own fill and ink.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? const Color(0xFF2B313A) : const Color(0xFF1A1E24),
      contentTextStyle: text.bodyMedium!.copyWith(color: Colors.white),
      actionTextColor: const Color(0xFF9DBCF8),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(CanaryRadius.container)),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      iconColor: p.muted,
      collapsedIconColor: p.muted,
      textColor: p.text,
      collapsedTextColor: p.text,
      shape: const Border(),
      collapsedShape: const Border(),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withAlpha(70),
      selectionHandleColor: p.accent,
    ),
  );
}

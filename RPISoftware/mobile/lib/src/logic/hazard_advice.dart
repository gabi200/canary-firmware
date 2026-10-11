import '../../l10n/app_localizations.dart';

/// The "don't" line on the alarm screen in the app language, backed up by the
/// signs from `hazardAdviceSigns()`.
String hazardDont(AppLocalizations l10n, String hazardType) => switch (hazardType) {
      'combustible_gas' => l10n.dontGas,
      'co' => l10n.dontCo,
      'particulate' => l10n.dontSmoke,
      'water_leak' => l10n.dontWaterLeak,
      _ => l10n.dontDefault,
    };

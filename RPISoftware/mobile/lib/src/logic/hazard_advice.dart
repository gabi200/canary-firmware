import '../../l10n/gen/app_localizations.dart';

String hazardDont(AppLocalizations l10n, String hazardType) => switch (hazardType) {
      'combustible_gas' => l10n.hazardGasDont,
      'co' => l10n.hazardCoDont,
      'particulate' => l10n.hazardSmokeDont,
      'water_leak' => l10n.hazardWaterDont,
      _ => l10n.hazardDefaultDont,
    };

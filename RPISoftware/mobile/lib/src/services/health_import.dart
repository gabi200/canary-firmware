import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logic/health_suggestions.dart';

/// Read-only Apple Health access through the `canary/health` channel
/// (ios/Runner/HealthImport.swift). iOS only; elsewhere [supported] is false
/// and the import button is hidden.
class HealthImport {
  const HealthImport();

  static const _channel = MethodChannel('canary/health');

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Asks for read access (the system sheet, first time only) and reads the
  /// latest wheelchair use, walking steadiness and audiogram. iOS never says
  /// whether read access was denied: denied and "no data" look the same.
  Future<HealthReading> read() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('read');
    return HealthReading.fromMap(raw ?? const {});
  }
}

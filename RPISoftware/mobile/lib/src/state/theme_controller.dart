import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/storage.dart';

/// Light / dark / follow the phone ("Aspect" in Settings). Dark until the user
/// picks; the choice is kept on this device.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(this._storage) : super(_parse(_storage.themeMode));

  final Storage _storage;

  static ThemeMode _parse(String? saved) => switch (saved) {
        'system' => ThemeMode.system,
        'light' => ThemeMode.light,
        _ => ThemeMode.dark,
      };

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await _storage.setThemeMode(mode.name);
  }
}

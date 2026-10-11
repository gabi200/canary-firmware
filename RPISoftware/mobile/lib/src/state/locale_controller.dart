import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n.dart';
import '../services/storage.dart';

/// Language used until the user picks one: Romanian when the device's preferred
/// language is Romanian, English otherwise.
String deviceLanguageCode([List<Locale>? deviceLocales]) {
  final locales = deviceLocales ?? PlatformDispatcher.instance.locales;
  return locales.isNotEmpty && locales.first.languageCode == 'ro' ? 'ro' : 'en';
}

/// The persisted choice when there is a valid one, else the device default.
String initialLanguageCode(Storage storage, [List<Locale>? deviceLocales]) {
  final saved = storage.languageCode;
  return saved != null && supportedLanguageCodes.contains(saved)
      ? saved
      : deviceLanguageCode(deviceLocales);
}

/// The app language (RO / EN). Drives MaterialApp.locale, the REST client's
/// Accept-Language header and local notification text; persisted only once the
/// user picks one, so until then the device language keeps deciding.
class LocaleController extends StateNotifier<Locale> {
  LocaleController(this._storage, {List<Locale>? deviceLocales})
      : super(Locale(initialLanguageCode(_storage, deviceLocales)));

  final Storage _storage;

  Future<void> setLanguage(String code) async {
    if (!supportedLanguageCodes.contains(code)) return;
    if (code != state.languageCode) state = Locale(code);
    await _storage.setLanguageCode(code);
  }
}

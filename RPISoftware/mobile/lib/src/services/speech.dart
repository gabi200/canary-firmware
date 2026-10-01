import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

abstract interface class Speech {
  /// Completes when the text has been read out (or speaking was stopped).
  Future<void> speak(String text, Locale locale);
  Future<void> stop();
}

class FlutterTtsSpeech implements Speech {
  FlutterTtsSpeech({FlutterTts? tts}) : _tts = tts ?? FlutterTts() {
    // Lets the screen flip its button back to "Read aloud" when reading finishes.
    _tts.awaitSpeakCompletion(true).catchError((_) => null);
  }

  final FlutterTts _tts;

  @override
  Future<void> speak(String text, Locale locale) async {
    final language = locale.languageCode == 'ro' ? 'ro-RO' : 'en-US';
    try {
      await _tts.setSpeechRate(0.45);
    } catch (_) {
      // A platform without this setting can still use its default voice.
    }
    try {
      if (await _tts.isLanguageAvailable(language)) {
        await _tts.setLanguage(language);
      }
    } catch (_) {
      // Keep the device's default voice when this language is unavailable.
    }
    try {
      await _tts.speak(text);
    } catch (_) {
      // Read-aloud is optional and must never interrupt evacuation guidance.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // There may be no speech engine available on this platform.
    }
  }
}

final speechProvider = Provider<Speech>((ref) => FlutterTtsSpeech());

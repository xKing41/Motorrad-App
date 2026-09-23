import 'dart:io' show Platform;

import 'package:flutter_tts/flutter_tts.dart';

/// Sprachansagen fuer die Navigation.
///
/// Laeuft ueber die Sprachausgabe des Handys - mit Helm-Headset per
/// Bluetooth ist das die wichtigste Art, Anweisungen zu bekommen: auf
/// dem Motorrad schaut man nicht aufs Display.
class Voice {
  Voice._();
  static final Voice instance = Voice._();

  FlutterTts? _tts;
  bool enabled = true;
  bool _ready = false;
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _init() async {
    if (_ready) return;
    try {
      final t = FlutterTts();
      await t.setLanguage('de-DE');
      await t.setSpeechRate(0.5);
      await t.setVolume(1.0);
      // Als Navigationsansage ausgeben: Musik im Headset wird waehrend
      // der Ansage leiser gestellt ("Ducking") statt sie zu uebertoenen
      // oder abzuwuergen, danach geht sie normal weiter.
      try {
        if (Platform.isAndroid) {
          await t.setAudioAttributesForNavigation();
        } else if (Platform.isIOS) {
          await t.setIosAudioCategory(
            IosTextToSpeechAudioCategory.playback,
            [
              IosTextToSpeechAudioCategoryOptions.duckOthers,
              IosTextToSpeechAudioCategoryOptions.mixWithOthers,
            ],
            IosTextToSpeechAudioMode.voicePrompt,
          );
        }
      } catch (_) {
        // Aeltere Geraete: Ansage ohne Ducking.
      }
      // Ansagen hintereinander statt sich gegenseitig abzuschneiden
      // (Abbiegung und Tankstopp kurz nacheinander).
      try {
        if (Platform.isAndroid) await t.setQueueMode(1);
      } catch (_) {}
      _tts = t;
    } catch (_) {
      _tts = null;
    }
    _ready = true;
  }

  /// Spricht [text]. Dieselbe Ansage wird nicht innerhalb weniger
  /// Sekunden wiederholt - ausser mit [repeat] (auf Wunsch des Fahrers).
  /// Mit [force] auch bei abgeschalteten Navigationsansagen (Sturzalarm).
  Future<void> say(String text, {bool force = false, bool repeat = false}) async {
    if ((!enabled && !force) || text.trim().isEmpty) return;
    final now = DateTime.now();
    if (!repeat && text == _last && now.difference(_lastAt).inSeconds < 8) {
      return;
    }
    _last = text;
    _lastAt = now;
    await _init();
    try {
      // focus: Audiofokus "kurz, andere leiser" anfordern (Ducking).
      await _tts?.speak(text, focus: true);
    } catch (_) {
      // Keine Sprachausgabe verfuegbar - Anzeige reicht.
    }
  }

  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}

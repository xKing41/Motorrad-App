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
      _tts = t;
    } catch (_) {
      _tts = null;
    }
    _ready = true;
  }

  /// Spricht [text]. Dieselbe Ansage wird nicht innerhalb weniger
  /// Sekunden wiederholt.
  /// Mit [force] auch bei abgeschalteten Navigationsansagen (Sturzalarm).
  Future<void> say(String text, {bool force = false}) async {
    if ((!enabled && !force) || text.trim().isEmpty) return;
    final now = DateTime.now();
    if (text == _last && now.difference(_lastAt).inSeconds < 8) return;
    _last = text;
    _lastAt = now;
    await _init();
    try {
      await _tts?.speak(text);
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

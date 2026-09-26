import 'dart:io' show Platform;

import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Eine Stimme der Sprachausgabe.
class TtsVoice {
  const TtsVoice(this.name, this.locale,
      {this.quality = '', this.network = false, this.installed = true});

  final String name;
  final String locale;

  /// "very high", "high", "normal", "low" ...
  final String quality;

  /// Braucht Internet (klingt oft besser, aber nicht im Funkloch).
  final bool network;
  final bool installed;

  static TtsVoice? fromMap(Object? m) {
    if (m is! Map) return null;
    final name = m['name']?.toString();
    final locale = m['locale']?.toString();
    if (name == null || locale == null) return null;
    final features = m['features']?.toString() ?? '';
    return TtsVoice(
      name,
      locale,
      quality: m['quality']?.toString() ?? '',
      network: m['network_required']?.toString() == '1' ||
          name.contains('network'),
      installed: !features.contains('notInstalled'),
    );
  }

  bool get german => locale.toLowerCase().startsWith('de');

  /// Bewertung fuer die automatische Wahl: Qualitaet zuerst, dann
  /// "funktioniert ohne Netz" (sonst schweigt das Navi im Funkloch),
  /// dann deutsches Deutsch vor Schweiz/Oesterreich.
  int get score {
    final q = switch (quality) {
      'very high' => 50,
      'high' => 40,
      'normal' => 30,
      'low' => 10,
      _ => 20,
    };
    return q +
        (network ? 0 : 15) +
        (installed ? 0 : -100) +
        (locale.toLowerCase().replaceAll('_', '-') == 'de-de' ? 5 : 0);
  }

  /// Anzeigename: "Stimme 3 · sehr hohe Qualität · offline".
  String label(int i) {
    final q = switch (quality) {
      'very high' => 'sehr hohe Qualität',
      'high' => 'hohe Qualität',
      'normal' => 'normale Qualität',
      'low' || 'very low' => 'einfache Qualität',
      _ => '',
    };
    final region = switch (locale.toLowerCase().replaceAll('_', '-')) {
      'de-at' => 'Österreich',
      'de-ch' => 'Schweiz',
      _ => '',
    };
    return [
      'Stimme ${i + 1}',
      if (region.isNotEmpty) region,
      if (q.isNotEmpty) q,
      network ? 'braucht Internet' : 'offline',
    ].join(' · ');
  }
}

/// Die beste Stimme aus einer Liste (null = keine deutsche).
TtsVoice? bestVoice(List<TtsVoice> voices) {
  final de = voices.where((v) => v.german && v.installed).toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  return de.isEmpty ? null : de.first;
}

/// Macht Ansagetexte fuer die Sprachausgabe natuerlicher: Strassen-
/// nummern werden als Zahl gelesen ("B 54" statt "B fuenf vier"),
/// Abkuerzungen ausgeschrieben.
String speakable(String t) => t
    .replaceAllMapped(RegExp(r'\b([ABLKS])(\d)'), (m) => '${m[1]} ${m[2]}')
    .replaceAll(RegExp(r'\bStr\.'), 'Straße')
    .replaceAll(RegExp(r' km/h\b'), ' Kilometer pro Stunde')
    .replaceAll(RegExp(r' km\b'), ' Kilometer')
    .replaceAll(RegExp(r' min\b'), ' Minuten');

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

  static const _kVoice = 'tts_voice';
  static const _kRate = 'tts_rate';

  /// Sprechtempo (0,4 langsam ... 0,6 schnell; 0,5 = normal).
  double rate = 0.5;
  TtsVoice? current;
  bool _ready = false;
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _init() async {
    if (_ready) return;
    try {
      final t = FlutterTts();
      await t.setLanguage('de-DE');
      final sp = await SharedPreferences.getInstance();
      rate = sp.getDouble(_kRate) ?? 0.5;
      await t.setSpeechRate(rate);
      await t.setVolume(1.0);
      await t.setPitch(1.0);
      // Die beste deutsche Stimme des Handys nehmen - die voreingestellte
      // ist oft eine einfache, roboterhafte. Eine selbst gewaehlte hat
      // Vorrang.
      try {
        final all = await _voicesOf(t);
        final saved = sp.getString(_kVoice);
        final pick = all.where((v) => v.name == saved).firstOrNull ??
            bestVoice(all);
        if (pick != null) {
          await t.setVoice({'name': pick.name, 'locale': pick.locale});
          current = pick;
        }
      } catch (_) {
        // Keine Stimmenliste: Standardstimme.
      }
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
      await _tts?.speak(speakable(text), focus: true);
    } catch (_) {
      // Keine Sprachausgabe verfuegbar - Anzeige reicht.
    }
  }

  static Future<List<TtsVoice>> _voicesOf(FlutterTts t) async {
    final raw = await t.getVoices;
    return [
      for (final m in (raw is List ? raw : const []))
        if (TtsVoice.fromMap(m) case final v?) v,
    ];
  }

  /// Alle deutschen Stimmen, beste zuerst - fuer die Auswahl.
  Future<List<TtsVoice>> germanVoices() async {
    await _init();
    final t = _tts;
    if (t == null) return const [];
    try {
      final l = (await _voicesOf(t)).where((v) => v.german && v.installed).toList()
        ..sort((a, b) => b.score.compareTo(a.score));
      return l;
    } catch (_) {
      return const [];
    }
  }

  Future<void> setVoice(TtsVoice v) async {
    await _init();
    try {
      await _tts?.setVoice({'name': v.name, 'locale': v.locale});
      current = v;
    } catch (_) {}
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kVoice, v.name);
  }

  Future<void> setRate(double r) async {
    rate = r.clamp(0.35, 0.65).toDouble();
    await _init();
    try {
      await _tts?.setSpeechRate(rate);
    } catch (_) {}
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kRate, rate);
  }

  /// Hoerprobe (auch bei abgeschalteten Ansagen).
  Future<void> sample() => say('In 400 Metern rechts auf die B 54.',
      force: true, repeat: true);

  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}

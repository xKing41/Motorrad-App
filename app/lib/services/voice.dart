import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
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
  // Automatisch nur Stimmen, die ohne Internet sprechen - eine
  // Online-Stimme schweigt im Funkloch oder bei schwachem Netz.
  // (Selbst waehlen kann man sie trotzdem.)
  final de = voices.where((v) => v.german && v.installed && !v.network).toList()
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

/// Wie die Ansagen ausgegeben werden.
enum VoiceOutput {
  /// Als Navigationsansage (Medienton, Musik wird leiser).
  auto('Normal (Navigation)'),

  /// Wie ein Anruf ueber die Bluetooth-Freisprechverbindung: unterbricht
  /// auch das Autoradio (Quelle Radio/DAB) und kommt bei manchen
  /// Headsets waehrend Intercom durch.
  call('Wie ein Anruf (Bluetooth)');

  const VoiceOutput(this.label);
  final String label;
}

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
  static const _kOutput = 'tts_output';
  static const _call = MethodChannel('schraeglage/callvoice');

  VoiceOutput output = VoiceOutput.auto;

  /// Letzter Fehler der Sprachausgabe (fuer die Diagnose).
  String? lastError;
  Future<void>? _initing;

  /// Sprechtempo (0,4 langsam ... 0,6 schnell; 0,5 = normal).
  double rate = 0.5;
  TtsVoice? current;
  bool _ready = false;
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _init() {
    if (_ready) return Future.value();
    // Gleichzeitige Aufrufe (Navistart: mehrere Ansagen) warten auf
    // dieselbe Einrichtung statt zwei Sprachausgaben anzulegen.
    return _initing ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      final t = FlutterTts();
      await t.setLanguage('de-DE');
      final sp = await SharedPreferences.getInstance();
      rate = sp.getDouble(_kRate) ?? 0.5;
      output = VoiceOutput.values.firstWhere(
          (o) => o.name == sp.getString(_kOutput),
          orElse: () => VoiceOutput.auto);
      t.setErrorHandler((m) => lastError = '$m');
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
          final r = await t.setVoice({'name': pick.name, 'locale': pick.locale});
          // Nicht angenommen: Standardstimme behalten.
          current = r == 1 ? pick : null;
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
    } catch (e) {
      lastError = 'Sprachausgabe nicht verfügbar: $e';
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
    final spoken = speakable(text);
    if (output == VoiceOutput.call && Platform.isAndroid) {
      try {
        await _call.invokeMethod('speak',
            {'text': spoken, 'rate': rate, 'voice': current?.name});
        return;
      } catch (e) {
        lastError = 'Anruf-Ausgabe: $e';
        // weiter mit der normalen Ausgabe
      }
    }
    try {
      // focus: Audiofokus "kurz, andere leiser" anfordern (Ducking).
      final r = await _tts?.speak(spoken, focus: true);
      if (r != null && r != 1) {
        // Nicht gesprochen (z. B. gewaehlte Stimme nicht nutzbar):
        // einmal mit der Standardstimme versuchen.
        lastError = 'Ansage nicht gesprochen ($r) - Standardstimme';
        await _tts?.clearVoice();
        current = null;
        await _tts?.speak(spoken, focus: true);
      }
    } catch (e) {
      lastError = 'Ansage fehlgeschlagen: $e';
    }
  }

  /// Schon beim App-Start einrichten: sonst geht die erste Ansage
  /// ("Los geht's") verloren, waehrend die Sprachausgabe noch laedt.
  Future<void> warmUp() => _init();

  Future<void> setOutput(VoiceOutput o) async {
    output = o;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kOutput, o.name);
  }

  /// Zustand der Sprachausgabe in Worten (Testansage, Fehlerbericht).
  Future<String> diagnose() async {
    await _init();
    final t = _tts;
    final b = StringBuffer();
    if (t == null) {
      b.writeln('Sprachausgabe: nicht verfügbar');
    } else {
      try {
        b.writeln('Sprachausgabe: ${await t.getDefaultEngine ?? '?'}');
        final de = await t.isLanguageAvailable('de-DE');
        b.writeln('Deutsch verfügbar: ${de == true ? 'ja' : 'nein'}');
      } catch (_) {}
    }
    b
      ..writeln('Stimme: ${current?.name ?? 'Standard'}')
      ..writeln('Ausgabe: ${output.label}')
      ..writeln('Ansagen eingeschaltet: ${enabled ? 'ja' : 'nein'}');
    var err = lastError;
    if (output == VoiceOutput.call && Platform.isAndroid) {
      try {
        err ??= await _call.invokeMethod<String>('lastError');
      } catch (_) {}
    }
    if (err != null) b.writeln('Letzter Fehler: $err');
    return b.toString().trim();
  }

  /// Testansage (auch bei abgeschalteten Ansagen).
  Future<void> test() => say(
      'Testansage. In 300 Metern rechts abbiegen.',
      force: true,
      repeat: true);

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
      final r = await _tts?.setVoice({'name': v.name, 'locale': v.locale});
      if (r == 1) current = v;
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
    if (output == VoiceOutput.call && Platform.isAndroid) {
      try {
        await _call.invokeMethod('stop');
      } catch (_) {}
    }
  }
}

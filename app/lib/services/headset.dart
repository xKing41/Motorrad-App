import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
//  HELM-HEADSET (Sena, Cardo, Interphone, Midland ... jedes Bluetooth-
//  Headset)
//
//  Die App konkurriert nicht mit dem Intercom der Headsets, sie nutzt sie:
//   * erkennt, welches Headset verbunden ist, und liest den Akkustand,
//   * warnt beim Navigationsstart, wenn keins verbunden ist (sonst kommen
//     die Ansagen ungehoert aus dem Handy),
//   * auf Wunsch steuern die Headset-Tasten die App,
//   * Sprachnachrichten fuer die Gruppe laufen ueber das Headset-Mikrofon.
//
//  Alles ueber normales Bluetooth - dafuer braucht es keine Zusammenarbeit
//  mit Sena oder Cardo. Intercom-Funktionen der Geraete (Mesh starten,
//  Gruppen) bleiben deren Apps vorbehalten.
// ---------------------------------------------------------------------------

class HeadsetStatus {
  const HeadsetStatus({
    this.connected = false,
    this.name = '',
    this.battery = -1,
    this.micPermission = false,
    this.btPermission = false,
  });

  final bool connected;
  final String name;

  /// Prozent, -1 = unbekannt.
  final int battery;
  final bool micPermission;
  final bool btPermission;

  static HeadsetStatus fromMap(Object? m) {
    if (m is! Map) return const HeadsetStatus();
    return HeadsetStatus(
      connected: m['connected'] == true,
      name: (m['name'] as String?) ?? '',
      battery: (m['battery'] as num?)?.toInt() ?? -1,
      micPermission: m['micPermission'] == true,
      btPermission: m['btPermission'] == true,
    );
  }

  /// Hersteller aus dem Geraetenamen - fuer die Anzeige.
  String get brand {
    final n = name.toLowerCase();
    if (n.contains('sena')) return 'Sena';
    if (n.contains('packtalk') || n.contains('freecom') || n.contains('cardo') ||
        n.contains('spirit')) {
      return 'Cardo';
    }
    if (n.contains('interphone')) return 'Interphone';
    if (n.contains('midland') || n.contains('btx') || n.contains('bt next')) {
      return 'Midland';
    }
    if (n.contains('schuberth') || n.contains('sc1') || n.contains('sc2')) {
      return 'Schuberth';
    }
    return '';
  }

  String get label {
    if (!connected) return 'Kein Headset';
    final b = battery >= 0 ? ' · $battery %' : '';
    return '${name.isEmpty ? 'Bluetooth-Headset' : name}$b';
  }

  bool get batteryLow => battery >= 0 && battery <= 20;
}

/// Was die Headset-Tasten in der App ausloesen.
enum HeadsetButton { playPause, next, previous }

class Headset extends ChangeNotifier {
  Headset._({MethodChannel? channel})
      : _ch = channel ?? const MethodChannel('schraeglage/headset');

  static final Headset instance = Headset._();

  @visibleForTesting
  factory Headset.forTest(MethodChannel ch) => Headset._(channel: ch);

  final MethodChannel _ch;
  HeadsetStatus status = const HeadsetStatus();
  final _buttons = StreamController<HeadsetButton>.broadcast();

  /// Tasten des Headsets (nur, wenn [setButtons] an ist).
  Stream<HeadsetButton> get buttons => _buttons.stream;

  bool buttonsOn = false;
  bool _init = false;

  static const _kButtons = 'headset_buttons';

  Future<void> init() async {
    if (_init) return;
    _init = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'changed':
          status = HeadsetStatus.fromMap(call.arguments);
          notifyListeners();
        case 'button':
          final b = switch (call.arguments) {
            'playpause' => HeadsetButton.playPause,
            'next' => HeadsetButton.next,
            'previous' => HeadsetButton.previous,
            _ => null,
          };
          if (b != null) _buttons.add(b);
      }
      return null;
    });
    await refresh();
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool(_kButtons) == true) await setButtons(true);
  }

  Future<void> refresh() async {
    try {
      status = HeadsetStatus.fromMap(await _ch.invokeMethod('status'));
      notifyListeners();
    } catch (_) {
      // Kein Android (Tests, Desktop): ohne Headset weiter.
    }
  }

  /// Mikrofon (und ab Android 12 Bluetooth) erlauben.
  Future<bool> requestPermissions() async {
    try {
      final ok = await _ch.invokeMethod<bool>('requestPermissions') ?? false;
      await refresh();
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> setButtons(bool on) async {
    buttonsOn = on;
    notifyListeners();
    try {
      await _ch.invokeMethod('setButtons', {'on': on});
    } catch (_) {}
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kButtons, on);
  }

  // -------------------------------------------------------------------
  //  Sprachnachrichten
  // -------------------------------------------------------------------

  String? _recPath;
  DateTime? _recStart;
  bool get recording => _recPath != null;

  /// Hoechstlaenge einer Nachricht.
  static const maxRecord = Duration(seconds: 20);

  Future<bool> startRecording() async {
    if (recording) return true;
    if (!status.micPermission) {
      if (!await requestPermissions()) return false;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/funk_${DateTime.now().millisecondsSinceEpoch}.m4a';
    try {
      final ok =
          await _ch.invokeMethod<bool>('startRecording', {'path': path}) ?? false;
      if (!ok) return false;
    } catch (_) {
      return false;
    }
    _recPath = path;
    _recStart = DateTime.now();
    notifyListeners();
    return true;
  }

  /// Aufnahme beenden. Rueckgabe: Aufnahme (Bytes) und Dauer, oder null
  /// (zu kurz, Fehler).
  Future<(Uint8List, Duration)?> stopRecording() async {
    final path = _recPath, start = _recStart;
    _recPath = null;
    _recStart = null;
    notifyListeners();
    if (path == null || start == null) return null;
    bool ok;
    try {
      ok = await _ch.invokeMethod<bool>('stopRecording') ?? false;
    } catch (_) {
      ok = false;
    }
    final dur = DateTime.now().difference(start);
    final f = File(path);
    if (!ok || dur < const Duration(milliseconds: 600) || !await f.exists()) {
      return null;
    }
    final bytes = await f.readAsBytes();
    unawaited(f.delete().catchError((_) => f));
    return (bytes, dur);
  }

  Duration get recordedSoFar =>
      _recStart == null ? Duration.zero : DateTime.now().difference(_recStart!);

  // Wiedergabe nacheinander (Nachrichten ueberlappen nicht).
  Future<void> _queue = Future.value();

  /// Spielt eine Sprachnachricht ueber das Headset (Musik wird leiser).
  Future<void> play(Uint8List audio) {
    final next = _queue.then((_) async {
      final dir = await getTemporaryDirectory();
      final f = File(
          '${dir.path}/rx_${DateTime.now().microsecondsSinceEpoch}.m4a');
      await f.writeAsBytes(audio);
      try {
        await _ch.invokeMethod('play', {'path': f.path});
      } catch (_) {}
      unawaited(f.delete().catchError((_) => f));
    });
    _queue = next.catchError((_) {});
    return next;
  }
}

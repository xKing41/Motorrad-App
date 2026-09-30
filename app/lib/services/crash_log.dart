import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../build_flavor.dart';

// ---------------------------------------------------------------------------
//  FEHLERPROTOKOLL
//
//  Stuerzt etwas ab, erfaehrt der Entwickler davon bisher nichts. Die App
//  schreibt Fehler deshalb in eine kleine Datei auf dem Handy - OHNE
//  Standort, Namen oder Telefonnummern. Beim naechsten Start fragt sie,
//  ob der Bericht verschickt werden soll (der Fahrer waehlt selbst, wie:
//  Mail, Messenger ...). Ohne Zustimmung verlaesst nichts das Handy.
// ---------------------------------------------------------------------------

class CrashLog {
  CrashLog._();
  static final CrashLog instance = CrashLog._();

  static const _kPending = 'crash_pending';
  static const int maxBytes = 60 * 1024;

  File? _file;
  final List<String> _early = [];

  /// Letzte Rechenzeiten der Planung o. ae. (fuer Fehlerberichte).
  final Map<String, String> context = {};

  Future<File> _open() async {
    final f = _file;
    if (f != null) return f;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/fehlerprotokoll.txt');
  }

  /// Fehlerfaenger einschalten (so frueh wie moeglich im main()).
  void install() {
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      prev?.call(details);
      // Layout-Ueberlaeufe sind Schoenheitsfehler, keine Abstuerze.
      final msg = details.exceptionAsString();
      if (msg.contains('overflowed')) return;
      record(details.exception, details.stack,
          where: details.library ?? 'Flutter', fatal: false);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      record(e, st, where: 'unbehandelt', fatal: true);
      return true;
    };
  }

  /// Einen Fehler festhalten. [fatal]: beim naechsten Start nachfragen.
  Future<void> record(Object error, StackTrace? stack,
      {String where = '', bool fatal = true}) async {
    final lines = (stack?.toString() ?? '').split('\n');
    final entry = StringBuffer()
      ..writeln('=== ${DateTime.now().toIso8601String()} · $where'
          '${fatal ? ' · SCHWER' : ''}')
      ..writeln('$error')
      ..writeln(lines.take(25).join('\n'));
    final text = entry.toString();
    _early.add(text);
    if (_early.length > 20) _early.removeAt(0);
    try {
      final f = await _open();
      var old = await f.exists() ? await f.readAsString() : '';
      old += text;
      if (old.length > maxBytes) old = old.substring(old.length - maxBytes);
      await f.writeAsString(old);
      if (fatal) {
        final sp = await SharedPreferences.getInstance();
        await sp.setBool(_kPending, true);
      }
    } catch (_) {
      // Protokoll ist Nebensache - nie selbst abstuerzen.
    }
  }

  /// Gab es beim letzten Mal einen schweren Fehler? (einmalig true)
  Future<bool> takePending() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final p = sp.getBool(_kPending) ?? false;
      if (p) await sp.remove(_kPending);
      return p;
    } catch (_) {
      return false;
    }
  }

  /// Letzte Eintraege (neueste zuletzt), hoechstens [maxChars] Zeichen.
  Future<String> recent({int maxChars = 12000}) async {
    var text = '';
    try {
      final f = await _open();
      if (await f.exists()) text = await f.readAsString();
    } catch (_) {
      text = _early.join();
    }
    if (text.length > maxChars) text = text.substring(text.length - maxChars);
    return text;
  }

  Future<void> clear() async {
    _early.clear();
    try {
      final f = await _open();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Kopf fuer jeden Bericht: Version, Ausgabe, Geraet - keine
  /// persoenlichen Daten.
  static String header() {
    final b = StringBuffer()
      ..writeln('$kAppName $kAppVersion')
      ..writeln('System: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}')
      ..writeln('Zeit: ${DateTime.now().toIso8601String()}');
    return b.toString();
  }

  /// Vollstaendiger Bericht zum Teilen.
  Future<String> report({String? userText}) async {
    final b = StringBuffer()
      ..writeln('SCHRÄGLAGE - FEHLERBERICHT')
      ..writeln()
      ..write(header());
    if (userText != null && userText.trim().isNotEmpty) {
      b
        ..writeln()
        ..writeln('BESCHREIBUNG:')
        ..writeln(userText.trim());
    }
    if (context.isNotEmpty) {
      b
        ..writeln()
        ..writeln('LETZTE WERTE:');
      for (final e in context.entries) {
        b.writeln('${e.key}: ${e.value}');
      }
    }
    final log = await recent();
    b
      ..writeln()
      ..writeln('FEHLERPROTOKOLL:')
      ..writeln(log.isEmpty ? '(keine Fehler aufgezeichnet)' : log);
    return b.toString();
  }
}

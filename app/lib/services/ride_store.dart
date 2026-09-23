import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/ride.dart';

/// Speichert Fahrten lokal auf dem Geraet.
///
/// Aufbau:
///   rides/index.json     -> Liste aller Zusammenfassungen (schnell zu laden)
///   rides/<id>.json      -> vollstaendiger Track einer Fahrt
///
/// Bewusst dateibasiert statt SharedPreferences: Ein Track mit ein paar
/// tausend Punkten sprengt die Preferences.
class RideStore {
  RideStore._([this._dir]);
  static final RideStore instance = RideStore._();

  /// Fuer Tests: Speicher in einem eigenen Ordner.
  @visibleForTesting
  factory RideStore.at(Directory dir) => RideStore._(dir);

  Directory? _dir;

  Future<Directory> _rideDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/rides');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  Future<File> _indexFile() async => File('${(await _rideDir()).path}/index.json');

  /// Schreibt erst in eine Hilfsdatei und benennt sie dann um. Stirbt die
  /// App mitten im Schreiben (Akku leer, System beendet sie), bleibt die
  /// alte Datei heil - vorher konnte dabei der ganze Index kaputtgehen,
  /// und beim naechsten Speichern waren alle Fahrten aus der Liste weg.
  static Future<void> _writeAtomic(File f, String content) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }

  Future<List<RideSummary>> listRides() async {
    List<RideSummary>? out;
    try {
      final f = await _indexFile();
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        if (raw is List) {
          out = raw
              .whereType<Map<String, dynamic>>()
              .map(RideSummary.fromJson)
              .toList();
        }
      }
    } catch (_) {
      out = null;
    }
    // Index fehlt oder ist beschaedigt: aus den Fahrtdateien neu aufbauen.
    out ??= await _rebuildIndex();
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  /// Liest die Zusammenfassungen aus den einzelnen Fahrtdateien (jede
  /// Datei traegt ihre Zusammenfassung selbst mit).
  Future<List<RideSummary>> _rebuildIndex() async {
    final out = <RideSummary>[];
    try {
      final d = await _rideDir();
      await for (final e in d.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        final name = e.uri.pathSegments.last;
        if (name == 'index.json' || name.startsWith('_')) continue;
        try {
          final raw = jsonDecode(await e.readAsString());
          if (raw is Map && raw['summary'] is Map<String, dynamic>) {
            out.add(RideSummary.fromJson(raw['summary'] as Map<String, dynamic>));
          }
        } catch (_) {
          // Einzelne kaputte Datei ueberspringen.
        }
      }
      if (out.isNotEmpty) await _writeIndex(out);
    } catch (_) {}
    return out;
  }

  Future<void> _writeIndex(List<RideSummary> rides) async {
    final f = await _indexFile();
    await _writeAtomic(
        f, jsonEncode(rides.map((r) => r.toJson()).toList()));
  }

  static String _rideJson(RideSummary summary, List<TrackPoint> track) =>
      jsonEncode({
        'summary': summary.toJson(),
        'track': track.map((p) => p.toJson()).toList(),
      });

  Future<void> saveRide(RideSummary summary, List<TrackPoint> track) async {
    final d = await _rideDir();
    await _writeAtomic(
        File('${d.path}/${summary.id}.json'), _rideJson(summary, track));
    final rides = await listRides();
    rides.removeWhere((r) => r.id == summary.id);
    rides.insert(0, summary);
    await _writeIndex(rides);
  }

  // -------------------------------------------------------------------
  //  Laufende Fahrt zwischenspeichern
  //
  //  Beendet Android die App waehrend der Fahrt (Akku, Speicher, Absturz),
  //  war bisher die ganze Fahrt weg - sie lag nur im Arbeitsspeicher.
  //  Jetzt wird sie regelmaessig gesichert und beim naechsten Start als
  //  Fahrt gespeichert.
  // -------------------------------------------------------------------
  Future<File> _activeFile() async =>
      File('${(await _rideDir()).path}/_active.json');

  Future<void> saveActive(RideSummary summary, List<TrackPoint> track) async {
    try {
      await _writeAtomic(await _activeFile(), _rideJson(summary, track));
    } catch (_) {}
  }

  Future<void> clearActive() async {
    try {
      final f = await _activeFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Speichert eine beim letzten Mal unterbrochene Fahrt. Rueckgabe: die
  /// gerettete Fahrt oder null.
  Future<RideSummary?> recoverActive() async {
    try {
      final f = await _activeFile();
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      await f.delete();
      if (raw is! Map || raw['summary'] is! Map<String, dynamic>) return null;
      final track = ((raw['track'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TrackPoint.fromJson)
          .toList();
      final s = RideSummary.fromJson(raw['summary'] as Map<String, dynamic>);
      if (track.length < 2 && s.distanceM < 100) return null;
      final saved = RideSummary(
        id: s.id,
        start: s.start,
        durationSec: s.durationSec,
        distanceM: s.distanceM,
        maxLeanL: s.maxLeanL,
        maxLeanR: s.maxLeanR,
        maxSpeedMs: s.maxSpeedMs,
        maxBrakeG: s.maxBrakeG,
        maxLatG: s.maxLatG,
        pointCount: track.length,
        title: 'Unterbrochene Fahrt',
      );
      await saveRide(saved, track);
      return saved;
    } catch (_) {
      return null;
    }
  }

  Future<List<TrackPoint>> loadTrack(String id) async {
    try {
      final f = File('${(await _rideDir()).path}/$id.json');
      if (!await f.exists()) return [];
      final raw = jsonDecode(await f.readAsString());
      final list = (raw is Map ? raw['track'] : raw) as List?;
      if (list == null) return [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(TrackPoint.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> deleteRide(String id) async {
    try {
      final f = File('${(await _rideDir()).path}/$id.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final rides = await listRides();
    rides.removeWhere((r) => r.id == id);
    await _writeIndex(rides);
  }

  /// Baut aus allen gespeicherten Fahrten eine grobe Karte der Strassen,
  /// auf denen der Fahrer schon unterwegs war - inklusive der dort
  /// erreichten Schraeglage.
  ///
  /// Das ist die Grundlage fuer "prefer_known_good_roads": Routen, die
  /// bevorzugt ueber Strecken fuehren, auf denen es dem Fahrer Spass
  /// gemacht hat. Diese Daten hat sonst niemand.
  ///
  /// Rasterung auf ~3 Nachkommastellen entspricht etwa 100 m.
  Future<Map<String, double>> buildLeanHeatmap({int maxRides = 40}) async {
    final out = <String, double>{};
    final rides = await listRides();
    for (final r in rides.take(maxRides)) {
      final track = await loadTrack(r.id);
      for (final p in track) {
        final key = heatCellKey(p.lat, p.lon);
        final v = p.lean.abs();
        if (v > (out[key] ?? 0)) out[key] = v;
      }
    }
    return out;
  }

  /// Gesamtstatistik ueber alle Fahrten.
  Future<Map<String, num>> totals() async {
    final rides = await listRides();
    double dist = 0;
    int dur = 0;
    double maxLean = 0;
    for (final r in rides) {
      dist += r.distanceM;
      dur += r.durationSec;
      final m = r.maxLeanL > r.maxLeanR ? r.maxLeanL : r.maxLeanR;
      if (m > maxLean) maxLean = m;
    }
    return {
      'rides': rides.length,
      'distanceM': dist,
      'durationSec': dur,
      'maxLean': maxLean,
    };
  }
}

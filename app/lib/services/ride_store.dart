import 'dart:convert';
import 'dart:io';

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
  RideStore._();
  static final RideStore instance = RideStore._();

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

  Future<List<RideSummary>> listRides() async {
    try {
      final f = await _indexFile();
      if (!await f.exists()) return [];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return [];
      final out = raw
          .whereType<Map<String, dynamic>>()
          .map(RideSummary.fromJson)
          .toList();
      out.sort((a, b) => b.start.compareTo(a.start));
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(List<RideSummary> rides) async {
    final f = await _indexFile();
    await f.writeAsString(jsonEncode(rides.map((r) => r.toJson()).toList()));
  }

  Future<void> saveRide(RideSummary summary, List<TrackPoint> track) async {
    final d = await _rideDir();
    await File('${d.path}/${summary.id}.json').writeAsString(
      jsonEncode({'track': track.map((p) => p.toJson()).toList()}),
    );
    final rides = await listRides();
    rides.removeWhere((r) => r.id == summary.id);
    rides.insert(0, summary);
    await _writeIndex(rides);
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
        final key = _cellKey(p.lat, p.lon);
        final v = p.lean.abs();
        if (v > (out[key] ?? 0)) out[key] = v;
      }
    }
    return out;
  }

  static String _cellKey(double lat, double lon) =>
      '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}';

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

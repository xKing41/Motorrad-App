import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';
import 'geo.dart';
import 'routing_engine.dart';
import 'speed_limits.dart';

// ---------------------------------------------------------------------------
//  STRASSEN-PRUEFUNG
//
//  Der Routing-Server kennt nur, was in OpenStreetMap steht. Ein
//  asphaltierter Wirtschaftsweg ohne Verbotsschild in der Karte sieht
//  fuer ihn aus wie eine kleine Strasse. Deshalb wird jede fertige Tour
//  noch einmal Stueck fuer Stueck angesehen ("trace_attributes": welche
//  Art Weg, welcher Belag). Feldwege, Fuss- und Radwege und - wenn
//  gewuenscht - Schotter werden gefunden; der Planer rechnet dann ohne
//  diese Stellen neu oder warnt.
// ---------------------------------------------------------------------------

/// Stueck der Route, das fuer ein Motorrad nicht taugt.
class RoadIssue {
  const RoadIssue(this.fromM, this.toM, this.kind);
  final double fromM;
  final double toM;

  /// "Feldweg", "Fuß-/Radweg", "unbefestigt".
  final String kind;

  double get lengthM => toM - fromM;

  @override
  String toString() => 'RoadIssue($kind ${fromM.round()}-${toM.round()})';
}

/// Ergebnis einer Pruefung: gefundene Stellen und was sich nicht
/// pruefen liess (kein Netz, Dienst ueberlastet).
class RoadCheckResult {
  const RoadCheckResult(this.issues, [this.unchecked = const []]);
  final List<RoadIssue> issues;

  /// Namen der Pruefungen, die ausgefallen sind ("Motorradverbote").
  final List<String> unchecked;

  bool get complete => unchecked.isEmpty;
}

abstract class RoadCheck {
  /// Wofuer die Pruefung steht (fuer "nicht geprueft: ...").
  String get name => 'Straßen';

  Future<List<RoadIssue>> check(List<RoutePoint> pts, {bool unpaved = true});

  /// Wie [check], wirft aber nie: Ausfall steht in [RoadCheckResult.unchecked].
  Future<RoadCheckResult> run(List<RoutePoint> pts,
      {bool unpaved = true}) async {
    try {
      return RoadCheckResult(await check(pts, unpaved: unpaved));
    } catch (_) {
      return RoadCheckResult(const [], [name]);
    }
  }
}

class ValhallaRoadCheck extends RoadCheck {
  ValhallaRoadCheck({
    this.base = 'https://valhalla1.openstreetmap.de',
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
    this.minInterval = const Duration(seconds: 1),
  }) : _client = client;

  /// Abstand zwischen Anfragen an den oeffentlichen Server.
  final Duration minInterval;

  @override
  String get name => 'Belag und Wegart';

  final String base;
  final http.Client? _client;
  final Duration timeout;

  /// Wegarten, auf denen ein Motorrad nichts verloren hat.
  static const Map<String, String> badUse = {
    'track': 'Feldweg',
    'footway': 'Fußweg',
    'sidewalk': 'Fußweg',
    'pedestrian': 'Fußgängerzone',
    'path': 'Pfad',
    'cycleway': 'Radweg',
    'mountain_bike': 'Radweg',
    'bridleway': 'Reitweg',
    'steps': 'Treppe',
    'pedestrian_crossing': 'Fußweg',
    'elevator': 'Fußweg',
    'emergency_access': 'Rettungszufahrt',
    'construction': 'Baustelle',
  };

  static const Set<String> badSurface = {'compacted', 'dirt', 'gravel'};

  @override
  Future<List<RoadIssue>> check(List<RoutePoint> pts,
      {bool unpaved = true}) async {
    if (pts.length < 2) return const [];
    final cum = cumulativeDistances(pts);
    // Dieselbe Tour (Planen, dann Navistart) nur einmal abfragen.
    final key = '$unpaved|${pts.length}|${pts.first.lat},${pts.first.lon}|'
        '${pts.last.lat},${pts.last.lon}|${cum.last.round()}';
    final hit = _cache[key];
    if (hit != null) return hit;
    final out = <RoadIssue>[];
    // Grosse Stuecke: weniger Anfragen (jede wartet auf ihren Takt).
    for (final (a, b) in ValhallaSpeedLimits.chunks(cum,
        maxM: chunkM, maxPoints: chunkMaxPoints)) {
      final part = pts.sublist(a, b + 1);
      final j = await _post(part);
      out.addAll(parse(j, cum[a], cum[b] - cum[a], unpaved: unpaved));
    }
    final res = merge(out);
    _cache[key] = res;
    if (_cache.length > 12) _cache.remove(_cache.keys.first);
    return res;
  }

  /// Stueckgroesse je Anfrage (Valhalla erlaubt standardmaessig bis
  /// 200 km und 16000 Punkte - mit Abstand darunter).
  static const double chunkM = 100000;
  static const int chunkMaxPoints = 4000;
  final Map<String, List<RoadIssue>> _cache = {};

  Future<Map<String, dynamic>> _post(List<RoutePoint> part) async {
    final uri = Uri.parse('$base/trace_attributes');
    const headers = {
      'Content-Type': 'application/json',
      'User-Agent': 'Schraeglage/4.34 (Motorrad-App)',
    };
    Future<http.Response> send(String costing) async {
      final body = jsonEncode({
        'encoded_polyline': encodePolyline(part),
        'shape_match': 'walk_or_snap',
        'costing': costing,
        'filters': {
          'attributes': [
            'edge.use',
            'edge.surface',
            'edge.unpaved',
            'edge.begin_shape_index',
            'edge.end_shape_index',
            'shape',
          ],
          'action': 'include',
        },
      });
      final c = _client;
      if (base == ValhallaEngine.publicUrl) {
        await ValhallaEngine.waitSlot(minInterval);
      }
      return (c != null
              ? c.post(uri, headers: headers, body: body)
              : http.post(uri, headers: headers, body: body))
          .timeout(timeout);
    }

    var res = await send('motorcycle');
    // Server ohne Motorrad-Profil: mit dem Auto-Profil zuordnen.
    if (res.statusCode == 400) res = await send('auto');
    if (res.statusCode != 200) {
      throw http.ClientException('trace_attributes ${res.statusCode}', uri);
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! Map<String, dynamic>) throw const FormatException();
    return data;
  }

  /// Liest die Antwort (wie bei den Tempolimits: Kanten verweisen auf die
  /// zurueckgegebene Linie, deren Laenge wird umgerechnet).
  static List<RoadIssue> parse(
      Map<String, dynamic> j, double startM, double lengthM,
      {bool unpaved = true}) {
    final edges = (j['edges'] as List?) ?? const [];
    final shapeEnc = j['shape'];
    if (edges.isEmpty || shapeEnc is! String) return const [];
    final shape = decodePolyline(shapeEnc);
    if (shape.length < 2) return const [];
    final cum = cumulativeDistances(shape);
    final scale = cum.last > 0 ? lengthM / cum.last : 1.0;
    final out = <RoadIssue>[];
    for (final e in edges.whereType<Map<String, dynamic>>()) {
      final kind = classify(e, unpaved: unpaved);
      final bi = (e['begin_shape_index'] as num?)?.toInt();
      final ei = (e['end_shape_index'] as num?)?.toInt();
      if (kind == null || bi == null || ei == null) continue;
      final a = cum[bi.clamp(0, cum.length - 1)];
      final b = cum[ei.clamp(0, cum.length - 1)];
      if (b <= a) continue;
      out.add(RoadIssue(startM + a * scale, startM + b * scale, kind));
    }
    return out;
  }

  /// Was stimmt mit der Kante nicht? null = in Ordnung.
  static String? classify(Map<String, dynamic> e, {bool unpaved = true}) {
    final use = e['use'];
    if (use is String && badUse.containsKey(use)) return badUse[use];
    final s = e['surface'];
    // Pfad-Belag oder unpassierbar: nie.
    if (s == 'path' || s == 'impassable') return 'unbefestigt';
    if (!unpaved) return null;
    if (s is String && badSurface.contains(s)) return 'unbefestigt';
    if (e['unpaved'] == true) return 'unbefestigt';
    return null;
  }

  /// Aneinandergrenzende Stuecke zusammenfassen (Luecken < 50 m).
  static List<RoadIssue> merge(List<RoadIssue> l) {
    if (l.isEmpty) return const [];
    final s = [...l]..sort((a, b) => a.fromM.compareTo(b.fromM));
    final out = <RoadIssue>[s.first];
    for (final x in s.skip(1)) {
      final last = out.last;
      if (x.fromM - last.toM < 50) {
        out[out.length - 1] = RoadIssue(last.fromM,
            math.max(last.toM, x.toM), last.kind);
      } else {
        out.add(x);
      }
    }
    return out;
  }
}

/// Was vom Ergebnis zaehlt: kurze Stuecke (Zuordnungsrauschen) und die
/// Umgebung von Start, Ziel und Stopps (Hofeinfahrt, Tankstelle) fallen
/// weg.
List<RoadIssue> relevantIssues(
  List<RoadIssue> issues,
  List<RoutePoint> pts, {
  List<RoutePoint> keepNear = const [],
  double minLengthM = 40,
  double nearM = 300,
}) {
  if (issues.isEmpty || pts.length < 2) return const [];
  final cum = cumulativeDistances(pts);
  final total = cum.last;
  final out = <RoadIssue>[];
  for (final i in issues) {
    if (i.lengthM < minLengthM) continue;
    if (i.toM <= nearM || i.fromM >= total - nearM) continue;
    final mid = pointAlong(pts, cum, (i.fromM + i.toM) / 2);
    if (keepNear.any((k) => dist(k, mid) < nearM)) continue;
    out.add(i);
  }
  return out;
}

/// Punkte zum Meiden: auf dem Stueck verteilt (alle ~400 m, mind. einer).
List<RoutePoint> issueAvoidPoints(List<RoadIssue> issues, List<RoutePoint> pts,
    {int max = 20}) {
  final cum = cumulativeDistances(pts);
  final out = <RoutePoint>[];
  for (final i in issues) {
    final n = math.max(1, (i.lengthM / 400).floor());
    for (var k = 0; k < n; k++) {
      out.add(pointAlong(pts, cum, i.fromM + i.lengthM * (k + 0.5) / n));
      if (out.length >= max) return out;
    }
  }
  return out;
}

/// Mehrere Pruefungen zusammen (Belag/Wegart und Verbote). Faellt eine
/// aus (kein Netz), zaehlen die anderen; fallen alle aus, gilt die Tour
/// als ungeprueft.
class CombinedRoadCheck extends RoadCheck {
  CombinedRoadCheck(this.checks);
  final List<RoadCheck> checks;

  @override
  Future<RoadCheckResult> run(List<RoutePoint> pts,
      {bool unpaved = true}) async {
    final issues = <RoadIssue>[];
    final unchecked = <String>[];
    // Gleichzeitig - die Pruefungen fragen verschiedene Dienste.
    final results = await Future.wait(
        [for (final c in checks) c.run(pts, unpaved: unpaved)]);
    for (final r in results) {
      issues.addAll(r.issues);
      unchecked.addAll(r.unchecked);
    }
    issues.sort((a, b) => a.fromM.compareTo(b.fromM));
    return RoadCheckResult(issues, unchecked);
  }

  @override
  Future<List<RoadIssue>> check(List<RoutePoint> pts,
      {bool unpaved = true}) async {
    final r = await run(pts, unpaved: unpaved);
    if (r.unchecked.length == checks.length && checks.isNotEmpty) {
      throw StateError('ungeprueft');
    }
    return r.issues;
  }
}

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

abstract class RoadCheck {
  Future<List<RoadIssue>> check(List<RoutePoint> pts, {bool unpaved = true});
}

class ValhallaRoadCheck implements RoadCheck {
  ValhallaRoadCheck({
    this.base = 'https://valhalla1.openstreetmap.de',
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
    this.minInterval = const Duration(seconds: 1),
  }) : _client = client;

  /// Abstand zwischen Anfragen an den oeffentlichen Server.
  final Duration minInterval;

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
    final out = <RoadIssue>[];
    for (final (a, b) in ValhallaSpeedLimits.chunks(cum)) {
      final part = pts.sublist(a, b + 1);
      final j = await _post(part);
      out.addAll(parse(j, cum[a], cum[b] - cum[a], unpaved: unpaved));
    }
    return merge(out);
  }

  Future<Map<String, dynamic>> _post(List<RoutePoint> part) async {
    final uri = Uri.parse('$base/trace_attributes');
    const headers = {
      'Content-Type': 'application/json',
      'User-Agent': 'Schraeglage/4.30 (Motorrad-App)',
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

import 'dart:async';
import 'dart:collection';

import '../models/route_plan.dart';
import 'geo.dart';
import 'poi_service.dart';

// ---------------------------------------------------------------------------
//  SPUREMPFEHLUNG
//
//  Welche Spur man vor einer Abbiegung, Ausfahrt oder Gabelung nehmen
//  soll, steht in OpenStreetMap als "turn:lanes" an der Strasse
//  (z. B. "left|through|through;right" = drei Spuren: links, geradeaus,
//  geradeaus oder rechts). Der kostenlose Routing-Server gibt diese Daten
//  nicht mit aus - deshalb holt die App sie einmal beim Planen selbst
//  (eine Overpass-Abfrage fuer alle Abbiegungen der Tour) und merkt sie
//  sich: Die Empfehlung funktioniert danach auch im Funkloch.
//
//  Abgedeckt ist, was in OSM eingetragen ist - in Deutschland fast alle
//  Autobahnausfahrten und groessere Kreuzungen, auf kleinen Landstrassen
//  selten (dort gibt es meist ohnehin nur eine Spur je Richtung).
// ---------------------------------------------------------------------------

/// Eine Spur mit ihren Pfeilen ("left", "through", "slight_right" ...).
class Lane {
  const Lane(this.indications, {this.recommended = false});
  final Set<String> indications;
  final bool recommended;

  Lane recommend(bool r) => Lane(indications, recommended: r);
}

/// Spuren vor einer Abbiegung, von links nach rechts.
class LaneInfo {
  const LaneInfo(this.lanes);
  final List<Lane> lanes;

  bool get useful =>
      lanes.length >= 2 &&
      lanes.any((l) => l.recommended) &&
      !lanes.every((l) => l.recommended);

  /// "rechte Spur", "die beiden linken Spuren", "mittlere Spur" ...
  String? get spoken {
    if (!useful) return null;
    final n = lanes.length;
    final idx = [for (var i = 0; i < n; i++) if (lanes[i].recommended) i];
    final k = idx.length;
    final contiguous = idx.last - idx.first + 1 == k;
    if (!contiguous) return null;
    const zahl = {2: 'beiden', 3: 'drei', 4: 'vier'};
    if (idx.last == n - 1) {
      return k == 1 ? 'die rechte Spur' : 'die ${zahl[k] ?? '$k'} rechten Spuren';
    }
    if (idx.first == 0) {
      return k == 1 ? 'die linke Spur' : 'die ${zahl[k] ?? '$k'} linken Spuren';
    }
    return k == 1 ? 'die mittlere Spur' : 'die mittleren Spuren';
  }
}

/// Liefert Spurempfehlungen je Anweisung (Index in der Anweisungsliste).
abstract class LaneSource {
  Future<Map<int, LaneInfo>> forRoute(
      List<RoutePoint> pts, List<RouteStep> steps);
}

/// Welche Pfeile zu einer Abbiegung passen.
Set<String> wantedFor(int type) {
  const left = {'left', 'sharp_left', 'slight_left'};
  const right = {'right', 'sharp_right', 'slight_right'};
  switch (type) {
    case ManeuverType.left:
    case ManeuverType.sharpLeft:
    case ManeuverType.uturnLeft:
      return {'left', 'sharp_left', 'reverse'};
    case ManeuverType.slightLeft:
    case ManeuverType.rampLeft:
    case ManeuverType.exitLeft:
    case ManeuverType.stayLeft:
      return left;
    case ManeuverType.right:
    case ManeuverType.sharpRight:
    case ManeuverType.uturnRight:
      return {'right', 'sharp_right'};
    case ManeuverType.slightRight:
    case ManeuverType.rampRight:
    case ManeuverType.exitRight:
    case ManeuverType.stayRight:
      return right;
    case ManeuverType.straight:
    case ManeuverType.stayStraight:
    case ManeuverType.becomes:
      return {'through', 'none', ''};
    default:
      return const {};
  }
}

/// Liest "left|through;right|" in Spuren (leere Spur = ohne Pfeil).
List<Set<String>> parseTurnLanes(String v) => [
      for (final lane in v.split('|'))
        {for (final i in lane.split(';')) i.trim().isEmpty ? 'none' : i.trim()},
    ];

/// Empfehlung fuer eine Abbiegung vom Typ [type].
LaneInfo? recommendLanes(List<Set<String>> lanes, int type) {
  final wanted = wantedFor(type);
  if (wanted.isEmpty || lanes.length < 2) return null;
  var info = [
    for (final l in lanes) Lane(l, recommended: l.any(wanted.contains)),
  ];
  // Bei Ausfahrt/Gabelung nach rechts ohne eigenen Pfeil: die aeusserste
  // Spur, wenn die ganz rechts etwas mit rechts zeigt.
  if (!info.any((l) => l.recommended)) return null;
  // Geradeaus: Spuren, die NUR abbiegen, sind falsch; kombinierte
  // (through;right) bleiben erlaubt.
  if (wanted.contains('through')) {
    info = [
      for (final l in info)
        l.recommend(l.indications.contains('through') ||
            l.indications.contains('none')),
    ];
  }
  return LaneInfo(info);
}

class OverpassLanes implements LaneSource {
  OverpassLanes({Future<Map<String, dynamic>?> Function(String q)? query})
      : _query = query ?? PoiService.overpass;

  static final OverpassLanes instance = OverpassLanes();

  final Future<Map<String, dynamic>?> Function(String q) _query;

  final Map<List<RoutePoint>, Future<Map<int, LaneInfo>>> _cache =
      LinkedHashMap.identity();

  /// Nur hier lohnen Spuren (Abbiegungen, Ausfahrten, Gabelungen).
  static bool relevant(int type) => wantedFor(type).isNotEmpty &&
      type != ManeuverType.straight &&
      type != ManeuverType.becomes;

  /// Wo vor der Abbiegung die Spuren gelesen werden (m davor).
  static const double lookBackM = 40;

  @override
  Future<Map<int, LaneInfo>> forRoute(
      List<RoutePoint> pts, List<RouteStep> steps) {
    final hit = _cache[pts];
    if (hit != null) return hit;
    final f = _fetch(pts, steps);
    _cache[pts] = f;
    while (_cache.length > 6) {
      _cache.remove(_cache.keys.first);
    }
    f.then((m) {
      if (m.isEmpty) _cache.remove(pts);
    }, onError: (_) {
      _cache.remove(pts);
    });
    return f;
  }

  /// Anfahrtspunkte: (Index der Anweisung, Punkt, Fahrtrichtung).
  static List<(int, RoutePoint, double)> approachPoints(
      List<RoutePoint> pts, List<RouteStep> steps) {
    if (pts.length < 2) return const [];
    final cum = cumulativeDistances(pts);
    final out = <(int, RoutePoint, double)>[];
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (!relevant(s.type) || s.pointIndex <= 0 || s.pointIndex >= pts.length) {
        continue;
      }
      final at = cum[s.pointIndex];
      if (at < lookBackM + 5) continue;
      final a = pointAlong(pts, cum, at - lookBackM);
      final b = pointAlong(pts, cum, at - lookBackM + 15);
      out.add((i, a, bearingDeg(a, b)));
    }
    return out;
  }

  static String buildQuery(List<(int, RoutePoint, double)> points) {
    final b = StringBuffer('[out:json][timeout:25];(');
    for (final (_, p, _) in points) {
      b.write('way(around:15,${p.lat.toStringAsFixed(6)},'
          '${p.lon.toStringAsFixed(6)})["highway"][~"^turn:lanes"~"."];');
    }
    b.write(');out tags geom;');
    return b.toString();
  }

  Future<Map<int, LaneInfo>> _fetch(
      List<RoutePoint> pts, List<RouteStep> steps) async {
    final points = approachPoints(pts, steps);
    if (points.isEmpty) return const {};
    final out = <int, LaneInfo>{};
    // Grosse Touren in Portionen (Overpass-Zeitlimit).
    for (var i = 0; i < points.length; i += 60) {
      final part = points.sublist(i, (i + 60).clamp(0, points.length));
      final data = await _query(buildQuery(part));
      if (data == null) continue;
      out.addAll(match(data, part, steps));
    }
    return out;
  }

  /// Ordnet die gefundenen Strassen den Anfahrtspunkten zu.
  static Map<int, LaneInfo> match(Map<String, dynamic> data,
      List<(int, RoutePoint, double)> points, List<RouteStep> steps) {
    final ways = <(List<RoutePoint>, Map<String, dynamic>)>[
      for (final e in (data['elements'] as List? ?? const [])
          .whereType<Map<String, dynamic>>())
        if (e['geometry'] is List && e['tags'] is Map)
          (
            [
              for (final g in (e['geometry'] as List).whereType<Map>())
                if (g['lat'] is num && g['lon'] is num)
                  RoutePoint((g['lat'] as num).toDouble(),
                      (g['lon'] as num).toDouble()),
            ],
            (e['tags'] as Map).cast<String, dynamic>(),
          ),
    ];
    final out = <int, LaneInfo>{};
    for (final (idx, p, brg) in points) {
      String? best;
      var bestD = 15.0;
      for (final (geom, tags) in ways) {
        if (geom.length < 2) continue;
        final cum = cumulativeDistances(geom);
        final hit = projectOnPolyline(p, geom, cum);
        if (hit == null || hit.distanceM > bestD) continue;
        final seg = hit.segment.clamp(0, geom.length - 2);
        final wayBrg = bearingDeg(geom[seg], geom[seg + 1]);
        final along = angleDiff(wayBrg, brg).abs() < 90;
        final oneway = '${tags['oneway'] ?? ''}';
        final isOneway = oneway == 'yes' ||
            oneway == '1' ||
            tags['highway'] == 'motorway' ||
            tags['highway'] == 'motorway_link' ||
            tags['junction'] == 'roundabout';
        String? v;
        if (isOneway) {
          // In Gegenrichtung einer Einbahnstrasse faehrt man nicht.
          if (!along) continue;
          v = tags['turn:lanes'] as String?;
        } else if (oneway == '-1') {
          if (along) continue;
          v = tags['turn:lanes'] as String?;
        } else {
          v = (along ? tags['turn:lanes:forward'] : tags['turn:lanes:backward'])
              as String?;
        }
        if (v == null || v.isEmpty) continue;
        best = v;
        bestD = hit.distanceM;
      }
      if (best == null) continue;
      final info = recommendLanes(parseTurnLanes(best), steps[idx].type);
      if (info != null && info.useful) out[idx] = info;
    }
    return out;
  }
}

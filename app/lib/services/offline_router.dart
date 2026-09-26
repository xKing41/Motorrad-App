import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_tile/vector_tile.dart';

import '../models/route_plan.dart';
import 'geo.dart';
import 'tile_cache.dart';

// ---------------------------------------------------------------------------
//  NEUBERECHNUNG OHNE NETZ
//
//  Der Routing-Server liegt im Internet - im Funkloch gab es bisher nur
//  "Neuberechnung nicht moeglich". Die Vektorkarte hat aber das
//  Strassennetz schon auf dem Handy: Jede Kachel enthaelt die Strassen
//  als Linien mit Art (Autobahn ... Feldweg) und Einbahn-Angabe. Daraus
//  baut die App hier ein kleines Netz und sucht den schnellsten Weg
//  zurueck zur Tour - vor den Fahrer, wie online auch.
//
//  Grenzen (deshalb nur als Notloesung, wenn der Server nicht erreichbar
//  ist): Abbiegeverbote kennen die Kartenkacheln nicht, Kreuzungen werden
//  aus gemeinsamen Punkten erkannt, und es geht nur so weit, wie Kacheln
//  gespeichert sind (entlang geplanter Routen und angesehener Gebiete).
// ---------------------------------------------------------------------------

/// Kachel-Zoomstufe der Strassendaten (OpenFreeMap liefert bis 14).
const int roadZoom = 14;
const int _extent = 4096;

/// Eine Strasse aus einer Kachel.
class RoadLine {
  RoadLine(this.nodes, this.cls, this.oneway, {this.unpaved = false});

  /// Punkte als globale Rasterkoordinaten (Zoom 14, 4096 je Kachel) -
  /// gleiche Punkte in Nachbarkacheln haben exakt dieselben Werte.
  final List<(int, int)> nodes;
  final String cls;

  /// 1 = nur in Zeichenrichtung, -1 = nur dagegen, 0 = beide.
  final int oneway;

  /// Kein fester Belag (laut Karte).
  final bool unpaved;
}

/// Rasterpunkt -> Koordinate.
RoutePoint gridToLatLon(int gx, int gy) {
  final n = (1 << roadZoom) * _extent.toDouble();
  final lon = gx / n * 360 - 180;
  final y = math.pi * (1 - 2 * gy / n);
  final lat = math.atan((math.exp(y) - math.exp(-y)) / 2) * 180 / math.pi;
  return RoutePoint(lat, lon);
}

(int, int) latLonToGrid(double lat, double lon) {
  final (x, y) = tileXY(lat, lon, roadZoom);
  return ((x * _extent).round(), (y * _extent).round());
}

int _asInt(VectorTileValue? v) {
  if (v == null) return 0;
  final i = v.intValue ?? v.sintValue ?? v.uintValue;
  if (i != null) return i.toInt();
  final d = v.doubleValue ?? v.floatValue;
  return d?.round() ?? 0;
}

/// Strassen einer Vektorkachel (OpenMapTiles, Ebene "transportation").
List<RoadLine> roadsFromTile(Uint8List bytes, int tx, int ty) {
  if (bytes.isEmpty) return const [];
  final VectorTile tile;
  try {
    tile = VectorTile.fromBytes(bytes: bytes);
  } catch (_) {
    return const [];
  }
  final out = <RoadLine>[];
  for (final layer in tile.layers) {
    if (layer.name != 'transportation') continue;
    final ext = layer.extent;
    for (final f in layer.features) {
      if (f.type != VectorTileGeomType.LINESTRING) continue;
      final props = f.decodeProperties();
      final cls = props['class']?.stringValue ?? '';
      if (!RoadNet.speedKmh.containsKey(cls)) continue;
      // Privat / fuer Kfz gesperrt (OpenMapTiles: access=no).
      if (props['access']?.stringValue == 'no') continue;
      final unpaved = props['surface']?.stringValue == 'unpaved';
      final ow = _asInt(props['oneway']);
      for (final line in f.decodeLineString()) {
        if (line.length < 2) continue;
        out.add(RoadLine([
          for (final c in line)
            (
              tx * _extent + (c[0] * _extent / ext).round(),
              ty * _extent + (c[1] * _extent / ext).round(),
            ),
        ], cls, ow, unpaved: unpaved));
      }
    }
  }
  return out;
}

class _Edge {
  _Edge(this.to, this.lengthM, this.cost);
  final int to;
  final double lengthM;
  final double cost;
}

/// Strassennetz aus Kachel-Linien.
class RoadNet {
  /// Reisetempo je Strassenart (km/h) fuer die Wegsuche.
  static const Map<String, double> speedKmh = {
    'motorway': 110,
    'trunk': 90,
    'primary': 80,
    'secondary': 70,
    'tertiary': 60,
    'minor': 40,
    'service': 8,
    'track': 12,
  };

  final List<(int, int)> _pos = [];
  final Map<(int, int), int> _id = {};
  final List<List<_Edge>> _adj = [];

  int get nodeCount => _pos.length;

  // Raster fuer die schnelle Suche "Knoten in der Naehe" (Zellen von
  // 256 Rastereinheiten, rund 100 m).
  static const int _cell = 256;
  final Map<(int, int), List<int>> _grid = {};

  int _node((int, int) p) => _id.putIfAbsent(p, () {
        _pos.add(p);
        _adj.add([]);
        final id = _pos.length - 1;
        _grid.putIfAbsent((p.$1 ~/ _cell, p.$2 ~/ _cell), () => []).add(id);
        return id;
      });

  RoutePoint pointOf(int n) => gridToLatLon(_pos[n].$1, _pos[n].$2);

  static RoadNet build(Iterable<RoadLine> lines,
      {bool avoidMotorways = false, bool avoidUnpaved = true}) {
    final net = RoadNet();
    for (final l in lines) {
      // Feldwege sind fuer Motorraeder fast immer gesperrt (Schild
      // "landwirtschaftlicher Verkehr frei") - auch asphaltierte.
      if (l.cls == 'track') continue;
      var v = speedKmh[l.cls]!;
      // Schotter: nicht verboten (sonst manchmal kein Weg), aber teuer.
      if (l.unpaved && avoidUnpaved) v /= 6;
      // "Ohne Autobahn": nicht verboten (sonst gibt es manchmal keinen
      // Weg), aber sehr teuer.
      if (avoidMotorways && (l.cls == 'motorway' || l.cls == 'trunk')) v /= 5;
      final ms = v / 3.6;
      for (var i = 0; i < l.nodes.length - 1; i++) {
        final a = l.nodes[i], b = l.nodes[i + 1];
        if (a == b) continue;
        final ia = net._node(a), ib = net._node(b);
        final d = dist(gridToLatLon(a.$1, a.$2), gridToLatLon(b.$1, b.$2));
        if (l.oneway >= 0) net._adj[ia].add(_Edge(ib, d, d / ms));
        if (l.oneway <= 0) net._adj[ib].add(_Edge(ia, d, d / ms));
      }
    }
    return net;
  }

  /// Knoten naeher als [maxM] an [p], naechster zuerst.
  List<int> nodesNear(RoutePoint p, double maxM, {int max = 6}) {
    final g = latLonToGrid(p.lat, p.lon);
    final list = <(int, double)>[];
    // 1 Rastereinheit ist in Mitteleuropa 0,3-0,6 m - grosszuegig suchen.
    final r = (maxM * 3 / _cell).ceil();
    final cx = g.$1 ~/ _cell, cy = g.$2 ~/ _cell;
    for (var x = cx - r; x <= cx + r; x++) {
      for (var y = cy - r; y <= cy + r; y++) {
        for (final i in _grid[(x, y)] ?? const <int>[]) {
          final d = dist(p, pointOf(i));
          if (d <= maxM) list.add((i, d));
        }
      }
    }
    list.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final e in list.take(max)) e.$1];
  }

  /// Schnellster Weg von einem der [starts] zu einem der [goals]
  /// (Knoten -> Zusatzkosten in s, z. B. fuer spaeteres Wiedereinfaedeln).
  List<int>? shortest(List<int> starts, Map<int, double> goals,
      {int maxVisited = 300000}) {
    if (starts.isEmpty || goals.isEmpty) return null;
    final dist = <int, double>{};
    final prev = <int, int>{};
    final heap = SplayTreeSet<(double, int)>((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    for (final s in starts) {
      dist[s] = 0;
      heap.add((0, s));
    }
    int? best;
    var bestCost = double.infinity;
    var visited = 0;
    while (heap.isNotEmpty) {
      final cur = heap.first;
      heap.remove(cur);
      final (c, n) = cur;
      if (c >= bestCost) break;
      if (c > (dist[n] ?? double.infinity)) continue;
      final g = goals[n];
      if (g != null && c + g < bestCost) {
        bestCost = c + g;
        best = n;
      }
      if (++visited > maxVisited) break;
      for (final e in _adj[n]) {
        final nc = c + e.cost;
        if (nc < (dist[e.to] ?? double.infinity)) {
          final old = dist[e.to];
          if (old != null) heap.remove((old, e.to));
          dist[e.to] = nc;
          prev[e.to] = n;
          heap.add((nc, e.to));
        }
      }
    }
    if (best == null) return null;
    final path = <int>[best];
    while (prev.containsKey(path.last)) {
      path.add(prev[path.last]!);
    }
    return path.reversed.toList();
  }

  int degree(int n) => _adj[n].length;
}

/// Eingabe fuer die Suche (laeuft in einem eigenen Isolate).
class OfflineRouteInput {
  OfflineRouteInput({
    required this.tiles,
    required this.here,
    required this.targets,
    this.avoidMotorways = false,
    this.avoidUnpaved = true,
  });

  /// (x, y, Bytes) der Kacheln im Suchgebiet.
  final List<(int, int, Uint8List)> tiles;
  final RoutePoint here;

  /// Moegliche Wiedereinstiege: (Punkt, Meter ab Start der Tour). Spaeter
  /// einsteigen kostet etwas mehr (ueberspringt Tour).
  final List<(RoutePoint, double)> targets;
  final bool avoidMotorways;
  final bool avoidUnpaved;
}

/// Ergebnis: Weg und die Stelle der Tour, an der er ankommt.
class OfflineRouteResult {
  OfflineRouteResult(this.points, this.joinAlongM, this.durationSec);
  final List<RoutePoint> points;
  final double joinAlongM;
  final int durationSec;
}

OfflineRouteResult? offlineRoute(OfflineRouteInput input) {
  final lines = <RoadLine>[
    for (final (x, y, b) in input.tiles) ...roadsFromTile(b, x, y),
  ];
  if (lines.isEmpty) return null;
  final net = RoadNet.build(lines,
      avoidMotorways: input.avoidMotorways, avoidUnpaved: input.avoidUnpaved);
  final starts = net.nodesNear(input.here, 150, max: 4);
  if (starts.isEmpty) return null;
  final goals = <int, double>{};
  final joinAt = <int, double>{};
  final firstAlong = input.targets.isEmpty ? 0.0 : input.targets.first.$2;
  for (final (p, along) in input.targets) {
    for (final n in net.nodesNear(p, 25, max: 2)) {
      // Jeder Meter uebersprungene Tour kostet (0,05 s/m) - so faehrt die
      // Rueckfuehrung nicht unnoetig weit vor.
      final extra = (along - firstAlong) * 0.05;
      if (extra < (goals[n] ?? double.infinity)) {
        goals[n] = extra;
        joinAt[n] = along;
      }
    }
  }
  final path = net.shortest(starts, goals);
  if (path == null || path.length < 2) return null;
  final pts = [for (final n in path) net.pointOf(n)];
  final len = pathLength(pts);
  return OfflineRouteResult(pts, joinAt[path.last]!, (len / (50 / 3.6)).round());
}

/// Abbiegehinweise aus der Linie: wo die Richtung deutlich wechselt.
List<RouteStep> stepsFromLine(List<RoutePoint> pts) {
  final steps = <RouteStep>[
    RouteStep(
        text: 'Zurück zur Tour (ohne Netz berechnet)',
        distanceM: 0,
        pointIndex: 0,
        type: ManeuverType.start),
  ];
  if (pts.length < 3) return steps;
  final cum = cumulativeDistances(pts);
  var lastStepAt = -1e9;
  for (var i = 1; i < pts.length - 1; i++) {
    final a = pointAlong(pts, cum, math.max(0, cum[i] - 20));
    final b = pointAlong(pts, cum, math.min(cum.last, cum[i] + 20));
    if (dist(a, pts[i]) < 5 || dist(pts[i], b) < 5) continue;
    final d = angleDiff(bearingDeg(a, pts[i]), bearingDeg(pts[i], b));
    if (d.abs() < 40 || cum[i] - lastStepAt < 40) continue;
    lastStepAt = cum[i];
    final right = d > 0;
    final sharp = d.abs() > 120;
    final type = right
        ? (sharp ? ManeuverType.sharpRight : ManeuverType.right)
        : (sharp ? ManeuverType.sharpLeft : ManeuverType.left);
    final text = sharp
        ? (right ? 'Scharf rechts abbiegen' : 'Scharf links abbiegen')
        : (right ? 'Rechts abbiegen' : 'Links abbiegen');
    steps.add(RouteStep(
        text: text,
        distanceM: 0,
        pointIndex: i,
        type: type,
        verbal: '$text.',
        alert: '$text.'));
  }
  return steps;
}

/// Sucht offline den Weg zurueck zur Tour. [loadTile] liefert eine
/// gespeicherte Kachel oder null.
class OfflineRerouter {
  OfflineRerouter(this.loadTile, {this.maxTiles = 80});

  final Future<Uint8List?> Function(TileKey k) loadTile;
  final int maxTiles;

  Future<OfflineRouteResult?> rejoin({
    required RoutePoint here,
    required List<RoutePoint> route,
    required double fromAlongM,
    bool avoidMotorways = false,
    bool avoidUnpaved = true,
  }) async {
    if (route.length < 2) return null;
    final cum = cumulativeDistances(route);
    final a = math.min(cum.last, fromAlongM + 200);
    final b = math.min(cum.last, fromAlongM + 8000);
    final targets = <(RoutePoint, double)>[
      for (var m = a; m <= b; m += 50) (pointAlong(route, cum, m), m),
    ];
    if (targets.isEmpty) return null;
    // Suchgebiet: Fahrer und Wiedereinstiege, plus 1,5 km Rand.
    var s = here.lat, n = here.lat, w = here.lon, e = here.lon;
    for (final (p, _) in targets) {
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
      w = math.min(w, p.lon);
      e = math.max(e, p.lon);
    }
    const pad = 0.014; // ~1,5 km
    final keys = tilesInBox(s - pad, w - pad * 1.5, n + pad, e + pad * 1.5,
            minZoom: roadZoom, maxZoom: roadZoom)
        .toList();
    if (keys.length > maxTiles) {
      // Zu gross: nur Kacheln nahe der Luftlinie Fahrer -> Tour.
      final mid = targets.first.$1;
      keys.sort((k1, k2) => _tileDist(k1, here, mid)
          .compareTo(_tileDist(k2, here, mid)));
      keys.removeRange(maxTiles, keys.length);
    }
    final tiles = <(int, int, Uint8List)>[];
    for (final k in keys) {
      final b = await loadTile(k);
      if (b != null && b.isNotEmpty) tiles.add((k.x, k.y, b));
    }
    if (tiles.isEmpty) return null;
    final input = OfflineRouteInput(
      tiles: tiles,
      here: here,
      targets: targets,
      avoidMotorways: avoidMotorways,
      avoidUnpaved: avoidUnpaved,
    );
    // Rechnen im Hintergrund, damit die Karte fluessig bleibt.
    return Isolate.run(() => offlineRoute(input));
  }

  static double _tileDist(TileKey k, RoutePoint a, RoutePoint b) {
    final n = 1 << k.z;
    final lon = (k.x + 0.5) / n * 360 - 180;
    final y = math.pi * (1 - 2 * (k.y + 0.5) / n);
    final lat = math.atan((math.exp(y) - math.exp(-y)) / 2) * 180 / math.pi;
    final c = RoutePoint(lat, lon);
    return math.min(dist(c, a), dist(c, b)) + dist(c, a) * 0.2;
  }
}

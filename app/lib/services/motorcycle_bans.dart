import 'dart:math' as math;

import '../models/route_plan.dart';
import 'geo.dart';
import 'poi_service.dart';
import 'road_check.dart';

// ---------------------------------------------------------------------------
//  MOTORRADVERBOTE
//
//  Manche ganz normalen Strassen sind fuer Motorraeder gesperrt - oft
//  genau die kurvigen (z. B. L 701 Breckerfeld - Hagen-Priorei), oft nur
//  zu bestimmten Zeiten ("Sa, So und Feiertag"). In OpenStreetMap steht
//  das als motorcycle=no bzw. motorcycle:conditional=no @ (...).
//
//  Der Routing-Server beachtet zeitweise Verbote nur, wenn er die
//  Uhrzeit kennt - beim Planen fuer "irgendwann" also nie. Deshalb wird
//  jede geplante Tour hier noch einmal abgeglichen: Liegt ein Stueck auf
//  einer gesperrten Strasse, wird es umfahren - auch wenn das Verbot
//  gerade nicht gilt. Eine Tour plant man selten fuer genau jetzt.
// ---------------------------------------------------------------------------

/// Gesperrter Weg aus OpenStreetMap.
class BannedWay {
  BannedWay(this.id, this.points, this.label);
  final int id;
  final List<RoutePoint> points;

  /// "Motorradverbot (Sa,Su,PH)", "nur Anlieger" ...
  final String label;

  late final (double, double, double, double) box = () {
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (final p in points) {
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
      w = math.min(w, p.lon);
      e = math.max(e, p.lon);
    }
    return (s, w, n, e);
  }();
}

class MotorcycleBans extends RoadCheck {
  MotorcycleBans({this.fetch});

  @override
  String get name => 'Motorradverbote';

  /// Overpass-Abfrage (austauschbar fuer Tests). null = Standard.
  final Future<Map<String, dynamic>?> Function(String query)? fetch;

  static const _restricted =
      'no|private|agricultural|forestry|agricultural;forestry|delivery|destination|permit|customers';
  static const _allowed = 'yes|designated|permissive';

  /// Suchkorridor entlang einer Linie. Die Linie wird nur so weit
  /// vereinfacht, dass sie hoechstens 30 m neben der Strasse liegt -
  /// eine grob vereinfachte Linie schneidet in Kurven ab, und der
  /// gesperrte Weg laege ausserhalb.
  static String area(List<RoutePoint> line, double corridorM) {
    final simple = corridorM >= 1000
        ? PoiService.corridor(line, corridorM)
        : null;
    if (simple != null) return simple;
    final pts = simplifyPath(line, 30);
    String f(double v) => v.toStringAsFixed(5);
    return '(around:${corridorM.round()},'
        '${pts.map((p) => '${f(p.lat)},${f(p.lon)}').join(',')})';
  }

  static String query(List<RoutePoint> route, {double corridorM = 120}) =>
      queryAll([route], corridorM: corridorM);

  /// Eine Abfrage fuer mehrere Linienstuecke.
  static String queryAll(List<List<RoutePoint>> lines,
      {double corridorM = 120}) {
    final b = StringBuffer('[out:json][timeout:40];(');
    for (final l in lines) {
      if (l.length < 2) continue;
      final a = area(l, corridorM);
      b
        ..write('way["highway"]["motorcycle"~"^($_restricted)\$"]$a;')
        ..write('way["highway"]["motorcycle:conditional"~"^ *($_restricted) *@"]$a;')
        ..write('way["highway"]["motor_vehicle"~"^($_restricted)\$"]'
            '["motorcycle"!~"^($_allowed)\$"]$a;')
        ..write('way["highway"]["motor_vehicle:conditional"~"^ *($_restricted) *@"]'
            '["motorcycle"!~"^($_allowed)\$"]$a;')
        ..write('way["highway"]["vehicle"~"^($_restricted)\$"]'
            '["motor_vehicle"!~"^($_allowed)\$"]["motorcycle"!~"^($_allowed)\$"]$a;')
        ..write('way["highway"]["access"~"^($_restricted)\$"]["vehicle"!~"^($_allowed)\$"]'
            '["motor_vehicle"!~"^($_allowed)\$"]["motorcycle"!~"^($_allowed)\$"]$a;');
    }
    b.write(');out tags geom 3000;');
    return b.toString();
  }

  static List<BannedWay> parse(Map<String, dynamic> data) {
    final out = <BannedWay>[];
    for (final e in ((data['elements'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()) {
      final geom = (e['geometry'] as List?) ?? const [];
      final pts = <RoutePoint>[
        for (final g in geom.whereType<Map>())
          if (g['lat'] is num && g['lon'] is num)
            RoutePoint((g['lat'] as num).toDouble(), (g['lon'] as num).toDouble()),
      ];
      if (pts.length < 2) continue;
      final tags = (e['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final l = label(tags);
      if (l == null) continue;
      out.add(BannedWay((e['id'] as num?)?.toInt() ?? 0, pts, l));
    }
    return out;
  }

  /// Was gilt fuer Motorraeder? null = frei.
  static String? label(Map<String, dynamic> t) {
    final restricted = RegExp('^($_restricted)\$');
    final allowed = RegExp('^($_allowed)\$');
    String kind(String v) => switch (v) {
          'destination' => 'nur Anlieger',
          'agricultural' ||
          'forestry' ||
          'agricultural;forestry' =>
            'nur Land-/Forstwirtschaft',
          'delivery' => 'nur Lieferverkehr',
          'private' || 'customers' || 'permit' => 'Privatweg',
          _ => 'gesperrt',
        };
    String? cond(String key) {
      final v = t[key];
      if (v is! String) return null;
      final m = RegExp(r'^\s*([a-z;]+)\s*@\s*\(?(.+?)\)?\s*$').firstMatch(v);
      if (m == null || !restricted.hasMatch(m.group(1)!)) return null;
      return m.group(2)!.trim();
    }

    // Vom Speziellen zum Allgemeinen - das erste, was etwas sagt, gilt.
    for (final key in ['motorcycle', 'motor_vehicle', 'vehicle', 'access']) {
      final v = t[key];
      final c = cond('$key:conditional');
      if (v is String && allowed.hasMatch(v)) {
        return c != null ? 'Motorradverbot ($c)' : null;
      }
      if (v is String && restricted.hasMatch(v)) {
        final k = kind(v);
        if (k == 'gesperrt') {
          return key == 'motorcycle' ? 'Motorradverbot' : 'gesperrt';
        }
        return k;
      }
      if (c != null) {
        return key == 'motorcycle' || key == 'motor_vehicle'
            ? 'Motorradverbot ($c)'
            : 'gesperrt ($c)';
      }
    }
    return null;
  }

  /// Gemeinsamer Speicher fuer die App: Planen, Navistart und
  /// Neuberechnung unterwegs fragen dieselbe Gegend nur einmal ab.
  static final MotorcycleBans shared = MotorcycleBans();

  // Schon abgefragte Gegend (Rasterzellen ~110 x 70 m entlang der
  // abgefragten Linien) und die dort gefundenen Wege.
  final Set<(int, int)> _covered = {};
  final Map<int, BannedWay> _ways = {};
  static const double _cell = 0.001;

  (int, int) _cellOf(RoutePoint p) =>
      ((p.lat / _cell).floor(), (p.lon / _cell).floor());

  /// Stuecke der Route, fuer die noch nicht abgefragt wurde.
  List<List<RoutePoint>> uncovered(List<RoutePoint> pts) {
    final cum = cumulativeDistances(pts);
    final out = <List<RoutePoint>>[];
    List<RoutePoint>? cur;
    void close() {
      final c = cur;
      if (c == null) return;
      // Einzelner Punkt: kurze Linie daraus (Abfrage braucht zwei).
      if (c.length == 1) c.add(destinationPoint(c.first, 0, 1));
      out.add(c);
      cur = null;
    }

    for (var a = 0.0; a <= cum.last + 1; a += 80) {
      final p = pointAlong(pts, cum, math.min(a, cum.last));
      if (_covered.contains(_cellOf(p))) {
        close();
      } else {
        (cur ??= []).add(p);
      }
    }
    close();
    return out;
  }

  void _markCovered(List<RoutePoint> line) {
    final cum = cumulativeDistances(line);
    for (var a = 0.0; a <= cum.last + 1; a += 40) {
      _covered.add(_cellOf(pointAlong(line, cum, math.min(a, cum.last))));
    }
  }

  @override
  Future<List<RoadIssue>> check(List<RoutePoint> pts,
      {bool unpaved = true}) async {
    if (pts.length < 2) return const [];
    final missing = uncovered(pts);
    if (missing.isNotEmpty) {
      final f = fetch ?? PoiService.overpass;
      final data = await f(queryAll(missing));
      if (data == null) throw StateError('Overpass nicht erreichbar');
      if (_ways.length > 20000) {
        _ways.clear();
        _covered.clear();
      }
      for (final w in parse(data)) {
        _ways[w.id] = w;
      }
      for (final l in missing) {
        _markCovered(l);
      }
    }
    // Nur Wege in der Gegend der Route vergleichen.
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (final p in pts) {
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
      w = math.min(w, p.lon);
      e = math.max(e, p.lon);
    }
    const pad = 0.002;
    return match(pts, [
      for (final x in _ways.values)
        if (x.box.$1 <= n + pad &&
            x.box.$3 >= s - pad &&
            x.box.$2 <= e + pad &&
            x.box.$4 >= w - pad)
          x,
    ]);
  }

  /// Gesperrte Wege im weiten Umkreis der Tour - fuer die Neuberechnung
  /// ohne Netz (wer sich verfaehrt, landet auch neben der Tour).
  Future<List<BannedWay>> around(List<RoutePoint> pts,
      {double corridorM = 2000}) async {
    if (pts.length < 2) return const [];
    final f = fetch ?? PoiService.overpass;
    final data = await f(query(pts, corridorM: corridorM));
    if (data == null) throw StateError('Overpass nicht erreichbar');
    return parse(data);
  }

  /// Wo faehrt die Route auf einem gesperrten Weg? Nur Stuecke, die
  /// laenger als [minRunM] darauf liegen - Kreuzungen zaehlen nicht.
  static List<RoadIssue> match(List<RoutePoint> route, List<BannedWay> ways,
      {double stepM = 20, double maxOffM = 4, double minRunM = 60}) {
    if (ways.isEmpty || route.length < 2) return const [];
    final cum = cumulativeDistances(route);
    final total = cum.last;
    const padDeg = 0.0003; // ~30 m
    final out = <RoadIssue>[];
    String? runLabel;
    var runFrom = 0.0, runTo = 0.0;
    void close() {
      if (runLabel != null && runTo - runFrom >= minRunM) {
        out.add(RoadIssue(runFrom, runTo, runLabel!));
      }
      runLabel = null;
    }

    for (var a = 0.0; a <= total; a += stepM) {
      final p = pointAlong(route, cum, a);
      String? hit;
      for (final w in ways) {
        final (s, west, n, e) = w.box;
        if (p.lat < s - padDeg ||
            p.lat > n + padDeg ||
            p.lon < west - padDeg ||
            p.lon > e + padDeg) {
          continue;
        }
        if (_distToLine(p, w.points) <= maxOffM) {
          hit = w.label;
          break;
        }
      }
      if (hit != null && hit == runLabel) {
        runTo = a;
      } else {
        close();
        if (hit != null) {
          runLabel = hit;
          runFrom = a;
          runTo = a;
        }
      }
    }
    close();
    return out;
  }

  static double _distToLine(RoutePoint p, List<RoutePoint> line) {
    final kx = 111320 * math.cos(p.lat * math.pi / 180);
    const ky = 110540.0;
    var best = double.infinity;
    for (var i = 0; i < line.length - 1; i++) {
      final ax = (line[i].lon - p.lon) * kx, ay = (line[i].lat - p.lat) * ky;
      final bx = (line[i + 1].lon - p.lon) * kx,
          by = (line[i + 1].lat - p.lat) * ky;
      final dx = bx - ax, dy = by - ay;
      final l2 = dx * dx + dy * dy;
      var t = l2 > 0 ? -(ax * dx + ay * dy) / l2 : 0.0;
      t = t.clamp(0.0, 1.0);
      final x = ax + t * dx, y = ay + t * dy;
      best = math.min(best, math.sqrt(x * x + y * y));
    }
    return best;
  }
}

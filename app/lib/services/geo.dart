import 'dart:math' as math;

import '../models/ride.dart' show distanceMeters;
import '../models/route_plan.dart' show RoutePoint;

// ---------------------------------------------------------------------------
//  GEOMETRIE FUER DIE ROUTENPLANUNG
//
//  Reine Rechnung ohne Netz und ohne Flutter - dadurch per Unit-Test
//  pruefbar. Hier steckt, woran die Planung "gut" von "schlecht"
//  unterscheidet: Kurvigkeit, doppelt gefahrene Abschnitte und
//  Stichstrassen, die nur hin und wieder zurueck fuehren.
// ---------------------------------------------------------------------------

const double _rad = math.pi / 180;
const double _earthR = 6371000.0;

/// Anfangskurs von [a] nach [b] in Grad (0 = Nord, 90 = Ost).
double bearingDeg(RoutePoint a, RoutePoint b) {
  final p1 = a.lat * _rad;
  final p2 = b.lat * _rad;
  final dl = (b.lon - a.lon) * _rad;
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) -
      math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) / _rad) % 360;
}

/// Punkt in [distM] Metern Entfernung von [p] in Richtung [bearing].
RoutePoint destinationPoint(RoutePoint p, double bearing, double distM) {
  final d = distM / _earthR;
  final b = bearing * _rad;
  final p1 = p.lat * _rad;
  final l1 = p.lon * _rad;
  final p2 = math.asin(math.sin(p1) * math.cos(d) +
      math.cos(p1) * math.sin(d) * math.cos(b));
  final l2 = l1 +
      math.atan2(math.sin(b) * math.sin(d) * math.cos(p1),
          math.cos(d) - math.sin(p1) * math.sin(p2));
  return RoutePoint(p2 / _rad, ((l2 / _rad) + 540) % 360 - 180);
}

/// Winkeldifferenz von [a] nach [b] in Grad, auf -180..180 normiert.
double angleDiff(double a, double b) {
  var d = (b - a) % 360;
  if (d > 180) d -= 360;
  return d;
}

double dist(RoutePoint a, RoutePoint b) =>
    distanceMeters(a.lat, a.lon, b.lat, b.lon);

/// Kumulierte Streckenlaenge je Punkt in Metern.
List<double> cumulativeDistances(List<RoutePoint> pts) {
  final out = List<double>.filled(pts.length, 0);
  for (var i = 1; i < pts.length; i++) {
    out[i] = out[i - 1] + dist(pts[i - 1], pts[i]);
  }
  return out;
}

double pathLength(List<RoutePoint> pts) {
  var s = 0.0;
  for (var i = 1; i < pts.length; i++) {
    s += dist(pts[i - 1], pts[i]);
  }
  return s;
}

/// Verteilt Punkte in gleichem Abstand entlang der Linie.
///
/// Routen haben sehr ungleich verteilte Stuetzpunkte: auf Geraden alle
/// paar hundert Meter einer, in Kurven alle paar Meter. Fuer jede
/// Auswertung "je Kilometer" muss das erst vereinheitlicht werden.
List<RoutePoint> resample(List<RoutePoint> pts, double stepM) {
  if (pts.length < 2 || stepM <= 0) return List.of(pts);
  final out = <RoutePoint>[pts.first];
  var carry = 0.0; // Strecke seit dem letzten ausgegebenen Punkt
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1];
    final b = pts[i];
    final seg = dist(a, b);
    if (seg <= 0) continue;
    var pos = stepM - carry;
    while (pos <= seg) {
      final t = pos / seg;
      out.add(RoutePoint(
        a.lat + (b.lat - a.lat) * t,
        a.lon + (b.lon - a.lon) * t,
      ));
      pos += stepM;
    }
    carry = seg - (pos - stepM);
  }
  if (carry > stepM * 0.25) out.add(pts.last);
  return out;
}

// ---------------------------------------------------------------------------
//  Polyline (Google-Verfahren) - Valhalla liefert Praezision 6
// ---------------------------------------------------------------------------

List<RoutePoint> decodePolyline(String enc, {int precision = 6}) {
  final factor = math.pow(10, precision).toDouble();
  final out = <RoutePoint>[];
  var index = 0;
  var lat = 0;
  var lon = 0;

  int? next() {
    var shift = 0;
    var result = 0;
    while (true) {
      if (index >= enc.length) return null;
      final b = enc.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
      if (b < 0x20) break;
    }
    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
  }

  while (index < enc.length) {
    final dLat = next();
    final dLon = next();
    if (dLat == null || dLon == null) break;
    lat += dLat;
    lon += dLon;
    out.add(RoutePoint(lat / factor, lon / factor));
  }
  return out;
}

String encodePolyline(List<RoutePoint> pts, {int precision = 6}) {
  final factor = math.pow(10, precision).toDouble();
  final b = StringBuffer();
  var pLat = 0;
  var pLon = 0;

  void put(int v) {
    var s = v < 0 ? ~(v << 1) : (v << 1);
    while (s >= 0x20) {
      b.writeCharCode((0x20 | (s & 0x1f)) + 63);
      s >>= 5;
    }
    b.writeCharCode(s + 63);
  }

  for (final p in pts) {
    final lat = (p.lat * factor).round();
    final lon = (p.lon * factor).round();
    put(lat - pLat);
    put(lon - pLon);
    pLat = lat;
    pLon = lon;
  }
  return b.toString();
}

// ---------------------------------------------------------------------------
//  Schnelle ebene Naeherung fuer kurze Abstaende
// ---------------------------------------------------------------------------

/// Rechnet Koordinaten in Meter um einen Bezugspunkt um. Fuer Vergleiche
/// auf wenigen Kilometern genau genug und viel schneller als Haversine.
class LocalProjection {
  LocalProjection(double lat0, double lon0)
      : _lat0 = lat0,
        _lon0 = lon0,
        _kx = 111320.0 * math.cos(lat0 * _rad);

  final double _lat0;
  final double _lon0;
  final double _kx;
  static const double _ky = 110574.0;

  double x(double lon) => (lon - _lon0) * _kx;
  double y(double lat) => (lat - _lat0) * _ky;
}

/// Ergebnis einer Projektion auf eine Linie.
class PolylineHit {
  const PolylineHit({
    required this.segment,
    required this.t,
    required this.distanceM,
    required this.alongM,
  });

  /// Index des Anfangspunktes des getroffenen Abschnitts.
  final int segment;

  /// Lage auf dem Abschnitt, 0..1.
  final double t;

  /// Seitlicher Abstand zur Linie.
  final double distanceM;

  /// Strecke vom Linienanfang bis zum Lotfusspunkt.
  final double alongM;
}

/// Lotet [p] auf die Linie [pts] (Abschnitte [from] bis [to]) und
/// liefert den naechstgelegenen Punkt. [cum] = [cumulativeDistances].
PolylineHit? projectOnPolyline(
  RoutePoint p,
  List<RoutePoint> pts,
  List<double> cum, {
  int from = 0,
  int? to,
}) {
  if (pts.length < 2) return null;
  final last = math.min(to ?? pts.length - 1, pts.length - 1);
  final first = math.max(0, math.min(from, last - 1));
  final proj = LocalProjection(p.lat, p.lon);
  PolylineHit? best;
  var bestD2 = double.infinity;
  for (var i = first; i < last; i++) {
    final a = pts[i];
    final b = pts[i + 1];
    final ax = proj.x(a.lon), ay = proj.y(a.lat);
    final bx = proj.x(b.lon), by = proj.y(b.lat);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 > 0 ? -(ax * dx + ay * dy) / len2 : 0.0;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final qx = ax + dx * t, qy = ay + dy * t;
    final d2 = qx * qx + qy * qy;
    if (d2 < bestD2) {
      bestD2 = d2;
      best = PolylineHit(
        segment: i,
        t: t,
        distanceM: math.sqrt(d2),
        alongM: cum[i] + (cum[i + 1] - cum[i]) * t,
      );
    }
  }
  return best;
}

/// Punkt nach [alongM] Metern auf der Linie.
RoutePoint pointAlong(List<RoutePoint> pts, List<double> cum, double alongM) {
  if (pts.isEmpty) throw ArgumentError('leere Linie');
  if (alongM <= 0) return pts.first;
  if (alongM >= cum.last) return pts.last;
  var lo = 0, hi = cum.length - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (cum[mid] <= alongM) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final seg = cum[hi] - cum[lo];
  final t = seg > 0 ? (alongM - cum[lo]) / seg : 0.0;
  final a = pts[lo], b = pts[hi];
  return RoutePoint(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t);
}

// ---------------------------------------------------------------------------
//  Kurvigkeit
// ---------------------------------------------------------------------------

/// Kennzahlen, wie kurvig eine Strecke ist.
class CurvatureStats {
  const CurvatureStats({
    required this.lengthM,
    required this.degPerKm,
    required this.curvyShare,
    required this.bendsPerKm,
  });

  static const empty =
      CurvatureStats(lengthM: 0, degPerKm: 0, curvyShare: 0, bendsPerKm: 0);

  final double lengthM;

  /// Summe aller Richtungsaenderungen je Kilometer in Grad.
  /// Autobahn etwa 10-30, Landstrasse 60-150, Bergstrecke 300 und mehr.
  final double degPerKm;

  /// Anteil der Strecke in echten Kurven (Radius unter etwa 250 m).
  final double curvyShare;

  /// Erkannte Kurven je Kilometer.
  final double bendsPerKm;

  /// Zusammengefasster Wert: 0 = schnurgerade, ~0,7 = typische kurvige
  /// Mittelgebirgsstrecke, 1,5 = Alpenpass.
  double get index =>
      0.45 * math.min(degPerKm / 220, 1.5) +
      0.35 * math.min(curvyShare / 0.30, 1.5) +
      0.20 * math.min(bendsPerKm / 2.5, 1.5);

  /// Einordnung fuer die Anzeige.
  String get label {
    final i = index;
    if (i >= 0.8) return 'sehr hoch';
    if (i >= 0.5) return 'hoch';
    if (i >= 0.25) return 'mittel';
    return 'gering';
  }
}

/// Misst die Kurvigkeit einer Linie.
///
/// Die Linie wird zuerst gleichmaessig verteilt (20 m), sonst wuerden
/// eng digitalisierte Strassen kurviger wirken als grob digitalisierte.
/// Kleinste Knicke unter 1 Grad sind Digitalisierungsrauschen und
/// zaehlen nicht.
CurvatureStats curvatureOf(List<RoutePoint> pts, {double stepM = 20}) {
  final r = resample(pts, stepM);
  if (r.length < 5) return CurvatureStats.empty;

  final headings = <double>[];
  for (var i = 1; i < r.length; i++) {
    headings.add(bearingDeg(r[i - 1], r[i]));
  }
  final d = <double>[];
  for (var i = 1; i < headings.length; i++) {
    d.add(angleDiff(headings[i - 1], headings[i]));
  }

  final lengthM = pathLength(r);
  if (lengthM < 200) return CurvatureStats.empty;

  var sumAbs = 0.0;
  for (final v in d) {
    final a = v.abs();
    if (a < 1.0) continue;
    sumAbs += math.min(a, 90.0);
  }

  // Richtungsaenderung ueber ein gleitendes Fenster von drei Schritten
  // (60 m). Radius r = Bogenlaenge / Winkel.
  final window = <double>[];
  for (var i = 1; i < d.length - 1; i++) {
    window.add(d[i - 1] + d[i] + d[i + 1]);
  }
  final curvyLimit = (3 * stepM / 250) / _rad; // Radius < 250 m
  const bendMin = 10.0; // Grad je Fenster, um in einer Kurve zu sein
  const bendTotal = 25.0; // eine Kurve muss insgesamt so weit drehen

  var curvyCount = 0;
  var bends = 0;
  var runSign = 0;
  var runTurn = 0.0;
  for (final w in window) {
    if (w.abs() >= curvyLimit) curvyCount++;
    final sign = w.abs() >= bendMin ? (w > 0 ? 1 : -1) : 0;
    if (sign != 0 && sign == runSign) {
      // Jeder Einzelknick steckt in drei Fenstern - daher ein Drittel.
      runTurn += w.abs() / 3;
    } else {
      if (runSign != 0 && runTurn >= bendTotal) bends++;
      runSign = sign;
      runTurn = sign == 0 ? 0 : w.abs() / 3;
    }
  }
  if (runSign != 0 && runTurn >= bendTotal) bends++;

  final km = lengthM / 1000;
  return CurvatureStats(
    lengthM: lengthM,
    degPerKm: sumAbs / km,
    curvyShare: window.isEmpty ? 0 : curvyCount / window.length,
    bendsPerKm: bends / km,
  );
}

// ---------------------------------------------------------------------------
//  Doppelt gefahrene Abschnitte
// ---------------------------------------------------------------------------

int _cellKey(int cx, int cy) => cx * 2000003 + cy;

/// Anteil der Strecke, der ein zweites Mal befahren wird - etwa weil die
/// Route in eine Sackgasse hinein und wieder heraus fuehrt oder auf dem
/// Rueckweg dieselbe Strasse nimmt.
///
/// Anfang und Ende werden ausgenommen: Von zu Hause weg und wieder nach
/// Hause fuehrt oft dieselbe Strasse, das ist kein Planungsfehler.
double overlapShare(
  List<RoutePoint> pts, {
  double stepM = 20,
  double tolM = 20,
  double minGapM = 400,
  double ignoreStartM = 800,
  double ignoreEndM = 800,
}) {
  final r = resample(pts, stepM);
  final n = r.length;
  if (n < 10) return 0;
  final proj = LocalProjection(r.first.lat, r.first.lon);
  final xs = List<double>.generate(n, (i) => proj.x(r[i].lon));
  final ys = List<double>.generate(n, (i) => proj.y(r[i].lat));
  final grid = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    final k = _cellKey((xs[i] / tolM).floor(), (ys[i] / tolM).floor());
    (grid[k] ??= <int>[]).add(i);
  }

  final gapSteps = (minGapM / stepM).ceil();
  final startSkip = (ignoreStartM / stepM).floor();
  final endSkip = n - 1 - (ignoreEndM / stepM).floor();
  final tol2 = tolM * tolM;
  var counted = 0;
  var doubled = 0;
  for (var i = startSkip; i <= endSkip && i < n; i++) {
    counted++;
    final cx = (xs[i] / tolM).floor();
    final cy = (ys[i] / tolM).floor();
    var hit = false;
    for (var gx = cx - 1; gx <= cx + 1 && !hit; gx++) {
      for (var gy = cy - 1; gy <= cy + 1 && !hit; gy++) {
        final cell = grid[_cellKey(gx, gy)];
        if (cell == null) continue;
        for (final j in cell) {
          if ((i - j).abs() < gapSteps) continue;
          final dx = xs[i] - xs[j], dy = ys[i] - ys[j];
          if (dx * dx + dy * dy <= tol2) {
            hit = true;
            break;
          }
        }
      }
    }
    if (hit) doubled++;
  }
  return counted == 0 ? 0 : doubled / counted;
}

// ---------------------------------------------------------------------------
//  Stichstrassen entfernen
// ---------------------------------------------------------------------------

/// Ergebnis von [removeSpurs].
class SpurCut {
  const SpurCut(this.points, this.indexMap, this.removedM);

  final List<RoutePoint> points;

  /// indexMap[alterIndex] = neuer Index, oder -1 wenn entfernt.
  final List<int> indexMap;

  /// Weggeschnittene Strecke in Metern.
  final double removedM;

  bool get changed => removedM > 0;
}

/// Schneidet "hin und wieder zurueck"-Abschnitte aus der Route.
///
/// Typischer Fall: Ein Wegpunkt landet an einer Sackgasse. Die Engine
/// faehrt pflichtbewusst hinein und auf demselben Weg wieder heraus.
/// Auf dem Motorrad ist das sinnlos - also raus damit.
///
/// Punkte in [keep] (z. B. Tankstopps) werden nie weggeschnitten: Zur
/// Tankstelle hin und zurueck ist gewollt.
SpurCut removeSpurs(
  List<RoutePoint> pts, {
  double maxSpurM = 6000,
  double tolM = 25,
  List<RoutePoint> keep = const [],
}) {
  final n = pts.length;
  final identity = List<int>.generate(n, (i) => i);
  if (n < 6) return SpurCut(List.of(pts), identity, 0);

  final cum = cumulativeDistances(pts);
  final proj = LocalProjection(pts.first.lat, pts.first.lon);
  final xs = List<double>.generate(n, (i) => proj.x(pts[i].lon));
  final ys = List<double>.generate(n, (i) => proj.y(pts[i].lat));

  final protected = List<bool>.filled(n, false);
  for (final k in keep) {
    final kx = proj.x(k.lon), ky = proj.y(k.lat);
    for (var i = 0; i < n; i++) {
      final dx = xs[i] - kx, dy = ys[i] - ky;
      if (dx * dx + dy * dy < 150 * 150) protected[i] = true;
    }
  }

  final grid = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    final k = _cellKey((xs[i] / tolM).floor(), (ys[i] / tolM).floor());
    (grid[k] ??= <int>[]).add(i);
  }

  final removed = List<bool>.filled(n, false);
  final tol2 = tolM * tolM;
  var removedM = 0.0;
  var i = 0;
  while (i < n - 2) {
    // Den spaetesten Punkt suchen, an dem die Route wieder hier vorbeikommt.
    var best = -1;
    final cx = (xs[i] / tolM).floor();
    final cy = (ys[i] / tolM).floor();
    for (var gx = cx - 1; gx <= cx + 1; gx++) {
      for (var gy = cy - 1; gy <= cy + 1; gy++) {
        final cell = grid[_cellKey(gx, gy)];
        if (cell == null) continue;
        for (final j in cell) {
          if (j <= i + 1 || j <= best) continue;
          final len = cum[j] - cum[i];
          if (len > maxSpurM || len < 4 * tolM) continue;
          final dx = xs[i] - xs[j], dy = ys[i] - ys[j];
          if (dx * dx + dy * dy <= tol2) best = j;
        }
      }
    }

    if (best > 0 && _isOutAndBack(pts, i, best, tolM)) {
      var prot = false;
      for (var k = i + 1; k < best; k++) {
        if (protected[k]) {
          prot = true;
          break;
        }
      }
      if (!prot) {
        for (var k = i + 1; k < best; k++) {
          removed[k] = true;
        }
        removedM += cum[best] - cum[i];
        i = best;
        continue;
      }
    }
    i++;
  }

  if (removedM == 0) return SpurCut(List.of(pts), identity, 0);
  final out = <RoutePoint>[];
  final map = List<int>.filled(n, -1);
  for (var k = 0; k < n; k++) {
    if (removed[k]) continue;
    map[k] = out.length;
    out.add(pts[k]);
  }
  return SpurCut(out, map, removedM);
}

/// Prueft, ob der Abschnitt [i]..[j] wirklich "hin und auf demselben Weg
/// zurueck" ist und nicht etwa eine kleine, echte Schleife.
bool _isOutAndBack(List<RoutePoint> pts, int i, int j, double tolM) {
  final sub = resample(pts.sublist(i, j + 1), 20);
  if (sub.length < 6) return false;

  // Muss sich ueberhaupt vom Ausgangspunkt entfernen.
  var far = 0.0;
  for (final p in sub) {
    final d = dist(sub.first, p);
    if (d > far) far = d;
  }
  if (far < 100) return false;

  final half = sub.length ~/ 2;
  final first = sub.sublist(0, half + 1);
  final second = sub.sublist(half);
  final proj = LocalProjection(sub.first.lat, sub.first.lon);
  final lim2 = (2 * tolM) * (2 * tolM);
  var near = 0;
  for (final q in second) {
    final qx = proj.x(q.lon), qy = proj.y(q.lat);
    for (final p in first) {
      final dx = proj.x(p.lon) - qx, dy = proj.y(p.lat) - qy;
      if (dx * dx + dy * dy <= lim2) {
        near++;
        break;
      }
    }
  }
  return near / second.length >= 0.7;
}

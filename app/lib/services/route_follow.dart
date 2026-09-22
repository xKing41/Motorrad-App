import 'dart:math' as math;

import '../models/route_plan.dart';
import 'geo.dart';

/// Zustand beim Abfahren einer Route.
class FollowState {
  FollowState({
    required this.nearestIndex,
    required this.offRouteM,
    required this.remainingM,
    required this.progress,
  });

  /// Index des Routenabschnitts, auf dem der Fahrer gerade ist.
  final int nearestIndex;

  /// Abstand zur Route in Metern.
  final double offRouteM;

  /// Reststrecke bis zum Ziel in Metern.
  final double remainingM;

  /// Fortschritt 0..1
  final double progress;

  bool get isOffRoute => offRouteM > 80;
  double get remainingKm => remainingM / 1000;
}

/// Begleitet das Abfahren einer Route: sucht die Position auf der Route,
/// misst den Abstand und rechnet die Reststrecke aus.
///
/// Zwei Fehler der alten Fassung sind hier behoben:
///  * Gemessen wurde der Abstand zum naechsten STUETZPUNKT. Auf langen
///    Geraden liegen die aber hunderte Meter auseinander - mitten auf der
///    Strecke hiess es dann "abseits der Route". Jetzt zaehlt der
///    Abstand zur Linie selbst.
///  * Bei Rundtouren liegen Start und Ziel am selben Ort. Die Suche fand
///    gleich zu Beginn oft das ENDE der Route - Anzeige "99 %, noch
///    0,1 km". Jetzt gewinnt bei gleichem Abstand die Stelle, die zum
///    bisherigen Fortschritt passt.
///
/// Bewusst schlank: kein Neuberechnen, keine Abbiege-Ansagen. Das ist der
/// "Follow-Modus" - die Route liegt auf der Karte, der Fahrer sieht, wo
/// er ist.
class RouteFollower {
  RouteFollower(this.plan) : _cum = cumulativeDistances(plan.points);

  final RoutePlan plan;
  final List<double> _cum;
  int _lastSeg = 0;
  double _lastAlong = 0;
  bool _locked = false;

  double get totalM => _cum.isEmpty ? 0 : _cum.last;

  FollowState? update(double lat, double lon) {
    final pts = plan.points;
    if (pts.length < 2) return null;
    final p = RoutePoint(lat, lon);

    PolylineHit? hit;
    if (_locked) {
      // Schnell: nur ein Fenster um die letzte Position absuchen.
      hit = projectOnPolyline(p, pts, _cum,
          from: _lastSeg - 30, to: _lastSeg + 300);
    }
    if (hit == null || hit.distanceM > 150) {
      hit = _searchAll(p);
    }
    if (hit == null) return null;

    _lastSeg = hit.segment;
    _lastAlong = hit.alongM;
    _locked = hit.distanceM < 150;

    final total = totalM;
    return FollowState(
      nearestIndex: hit.segment,
      offRouteM: hit.distanceM,
      remainingM: (total - hit.alongM).clamp(0.0, total),
      progress: total > 0 ? (hit.alongM / total).clamp(0.0, 1.0) : 0,
    );
  }

  /// Sucht auf der ganzen Route. Unter allen Stellen, die fast so nah
  /// liegen wie die naechste, gewinnt die erste, die zum bisherigen
  /// Fortschritt passt.
  PolylineHit? _searchAll(RoutePoint p) {
    final pts = plan.points;
    final n = pts.length - 1;
    final proj = LocalProjection(p.lat, p.lon);
    final dist = List<double>.filled(n, 0);
    final ts = List<double>.filled(n, 0);
    var best = double.infinity;
    for (var i = 0; i < n; i++) {
      final ax = proj.x(pts[i].lon), ay = proj.y(pts[i].lat);
      final bx = proj.x(pts[i + 1].lon), by = proj.y(pts[i + 1].lat);
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 > 0 ? -(ax * dx + ay * dy) / len2 : 0.0;
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      final qx = ax + dx * t, qy = ay + dy * t;
      final d = math.sqrt(qx * qx + qy * qy);
      dist[i] = d;
      ts[i] = t;
      if (d < best) best = d;
    }

    int? firstAny;
    int? firstForward;
    for (var i = 0; i < n; i++) {
      if (dist[i] > best + 40) continue;
      firstAny ??= i;
      final along = _cum[i] + (_cum[i + 1] - _cum[i]) * ts[i];
      if (along >= _lastAlong - 200) {
        firstForward = i;
        break;
      }
    }
    final i = firstForward ?? firstAny;
    if (i == null) return null;
    return PolylineHit(
      segment: i,
      t: ts[i],
      // Angezeigt wird der echte kleinste Abstand, auch wenn eine
      // (bis zu 40 m) weiter entfernte Stelle als Position gewaehlt wurde.
      distanceM: best,
      alongM: _cum[i] + (_cum[i + 1] - _cum[i]) * ts[i],
    );
  }

  void reset() {
    _lastSeg = 0;
    _lastAlong = 0;
    _locked = false;
  }
}

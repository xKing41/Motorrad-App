import 'dart:math' as math;

import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/routing_engine.dart';

/// Gerade Linie ab [a] in Richtung [bearing], Stuetzpunkt alle [step] m.
List<RoutePoint> straight(RoutePoint a, double bearing, double lengthM,
    {double step = 100}) {
  final n = (lengthM / step).ceil();
  return [
    for (var i = 0; i <= n; i++)
      destinationPoint(a, bearing, math.min(i * step, lengthM)),
  ];
}

/// Kurvige Strasse: Sinus quer zur Fahrtrichtung.
List<RoutePoint> wiggly(
  RoutePoint a,
  double bearing,
  double lengthM, {
  required double amplitude,
  required double wavelength,
  double step = 10,
}) {
  final out = <RoutePoint>[];
  for (var s = 0.0; s <= lengthM; s += step) {
    final base = destinationPoint(a, bearing, s);
    final off = amplitude * math.sin(2 * math.pi * s / wavelength);
    out.add(destinationPoint(base, bearing + 90, off));
  }
  return out;
}

/// Kreis um [center] im Uhrzeigersinn, beginnend bei [startAngle].
List<RoutePoint> circle(RoutePoint center, double radius,
        {int n = 180, double startAngle = 0}) =>
    [
      for (var i = 0; i <= n; i++)
        destinationPoint(center, startAngle + 360 * i / n, radius),
    ];

/// Engine ohne Netz: verbindet die Wegpunkte mit geraden, dicht
/// besetzten Linien. [factor] > 1 streckt die Strecke kuenstlich (wie
/// Strassen, die Umwege machen), indem jede Teilstrecke als Zickzack
/// gefahren wird.
class FakeEngine implements RoutingEngine {
  FakeEngine({this.factor = 1.0, this.maxWaypoints = 20, this.failEvery = 0});

  final double factor;
  final int failEvery;
  int calls = 0;
  final List<List<Waypoint>> requests = [];

  @override
  final int maxWaypoints;

  @override
  String get label => 'Test';

  @override
  int get parallelRequests => 2;

  @override
  Future<List<EngineRoute>> route(List<Waypoint> wps, RoutingPrefs prefs,
      {int alternates = 0}) async {
    calls++;
    requests.add(wps);
    if (failEvery > 0 && calls % failEvery == 0) {
      throw RouteException('kein Weg (Test)');
    }
    final pts = <RoutePoint>[];
    for (var i = 0; i < wps.length - 1; i++) {
      final a = wps[i].point, b = wps[i + 1].point;
      final d = dist(a, b);
      if (d < 1) continue;
      final brg = bearingDeg(a, b);
      final n = math.max(2, (d / 50).ceil());
      // Zickzack quer zur Richtung, so dass die Laenge um [factor] waechst.
      final amp = factor > 1 ? 50 * math.sqrt(factor * factor - 1) / 2 : 0.0;
      for (var j = 0; j < n; j++) {
        final base = destinationPoint(a, brg, d * j / n);
        final off = (j.isOdd ? amp : -amp) * (j == 0 ? 0 : 1);
        pts.add(destinationPoint(base, brg + 90, off));
      }
    }
    pts.add(wps.last.point);
    final len = pathLength(pts);
    return [
      EngineRoute(points: pts, distanceM: len, durationSec: (len / 20).round()),
    ];
  }
}

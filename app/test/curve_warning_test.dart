import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/curve_warning.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/navigation.dart';
import 'package:schraeglage/services/routing_engine.dart';

import 'helpers.dart';

/// Gerade, dann ein Kreisbogen mit [radius] und [angle] Grad (+ = rechts),
/// dann wieder gerade.
List<RoutePoint> bend(double radius, double angle,
    {double before = 1000, double after = 1000}) {
  const start = RoutePoint(47.8, 8.0);
  final pts = <RoutePoint>[...straight(start, 0, before, step: 25)];
  var p = pts.last;
  var h = 0.0;
  final arc = radius * angle.abs() * math.pi / 180;
  final n = math.max(4, (arc / 3).ceil());
  for (var i = 0; i < n; i++) {
    final d = angle / n;
    h += d / 2;
    p = destinationPoint(p, h, arc / n);
    h += d / 2;
    pts.add(p);
  }
  pts.addAll(straight(p, h, after, step: 25).skip(1));
  return pts;
}

void main() {
  test('Spitzkehre rechts wird erkannt, Radius ungefaehr richtig', () {
    final c = CurveFinder.find(bend(15, 170));
    expect(c.length, 1);
    expect(c.single.right, isTrue);
    expect(c.single.hairpin, isTrue);
    expect(c.single.minRadiusM, inInclusiveRange(10, 22));
    expect(c.single.angleDeg, inInclusiveRange(140, 200));
    expect(c.single.startM, inInclusiveRange(950, 1010));
    expect(c.single.label, 'Spitzkehre rechts');
  });

  test('enge Linkskurve 90 Grad, r 40 m', () {
    final c = CurveFinder.find(bend(40, -90));
    expect(c.length, 1);
    expect(c.single.right, isFalse);
    expect(c.single.hairpin, isFalse);
    expect(c.single.minRadiusM, inInclusiveRange(30, 55));
    expect(c.single.label, 'Enge Linkskurve');
    // Richttempo bei 0,35 g: sqrt(0,35*9,81*40) = 11,7 m/s = 42 km/h.
    expect(c.single.adviseKmh, inInclusiveRange(35, 50));
  });

  test('weite Landstrassenkurve und Gerade: keine Warnung', () {
    expect(CurveFinder.find(bend(300, 90)), isEmpty);
    expect(CurveFinder.find(straight(const RoutePoint(47, 8), 45, 3000)),
        isEmpty);
    // Kleiner Knick (Linie ungenau) - keine Kurve.
    expect(CurveFinder.find(bend(20, 30)), isEmpty);
  });

  test('Abbiegen an einer Kreuzung ist keine Kurvenwarnung', () {
    final pts = bend(10, 90);
    expect(CurveFinder.find(pts), isNotEmpty);
    expect(CurveFinder.find(pts, skipNear: [1008]), isEmpty);
  });

  test('gewarnt wird nur bei zu hohem Tempo, rechtzeitig', () {
    final c = CurveFinder.find(bend(15, 170)).single;
    // 100 km/h: Bremsweg + Vorlauf deutlich ueber 100 m.
    expect(CurveFinder.shouldWarn(c, 150, 100 / 3.6), isTrue);
    expect(CurveFinder.shouldWarn(c, 400, 100 / 3.6), isFalse);
    // Schon langsam: nie.
    expect(CurveFinder.shouldWarn(c, 50, 30 / 3.6), isFalse);
  });

  test('Navigation: Anzeige und eine Ansage je Kurve', () {
    final pts = bend(15, 170, before: 3000);
    final said = <String>[];
    final nav = NavigationSession(
      plan: RoutePlan(points: pts, distanceM: pathLength(pts), steps: [
        RouteStep(text: 'Los', distanceM: 0, pointIndex: 0, type: ManeuverType.start),
        RouteStep(text: 'Ziel', distanceM: 0, pointIndex: pts.length - 1,
            type: ManeuverType.destination),
      ]),
      engine: FakeEngine(),
      prefs: const RoutingPrefs(),
      speak: said.add,
    );
    expect(nav.curves.length, 1);
    final cum = cumulativeDistances(pts);
    for (final at in [1000.0, 2600.0, 2800.0, 2850.0]) {
      final p = pointAlong(pts, cum, at);
      nav.update(p.lat, p.lon, speedMs: 90 / 3.6);
    }
    expect(nav.curveAhead, isNotNull);
    expect(said.where((s) => s.contains('Spitzkehre rechts')).length, 1);
    // Langsam genug: keine Anzeige mehr.
    final p = pointAlong(pts, cum, 2900);
    nav.update(p.lat, p.lon, speedMs: 25 / 3.6);
    expect(nav.curveAhead, isNull);
  });
}

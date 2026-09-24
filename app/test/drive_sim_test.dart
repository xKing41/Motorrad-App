import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/drive_sim.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/speed_limits.dart';

import 'helpers.dart';

/// Gerade, Spitzkehre (r 15 m), Gerade.
List<RoutePoint> hairpinRoute() {
  const start = RoutePoint(47.8, 8.0);
  final pts = <RoutePoint>[...straight(start, 0, 2000, step: 25)];
  var p = pts.last;
  var h = 0.0;
  const r = 15.0;
  const arc = r * math.pi;
  for (var i = 0; i < 30; i++) {
    h += 3;
    p = destinationPoint(p, h, arc / 30);
    h += 3;
    pts.add(p);
  }
  pts.addAll(straight(p, h, 2000, step: 25).skip(1));
  return pts;
}

void main() {
  test('Tempoprofil: Stillstand an Start und Ziel, langsam in der Kehre', () {
    final pts = hairpinRoute();
    final sim = DriveSimulator()..setRoute(pts);
    final v = sim.profile;
    expect(v.first, 0);
    expect(v.last, 0);
    final maxV = v.reduce(math.max);
    expect(maxV * 3.6, closeTo(100, 1)); // freie Strecke: 100 km/h
    // In der Kehre (ca. bei 2000-2050 m) Schritt- bis Kehrentempo.
    final kehre = v.sublist(200, 205).reduce(math.min);
    expect(kehre * 3.6, lessThan(30));
    // Sanft: keine Spruenge groesser als erlaubt.
    for (var i = 1; i < v.length; i++) {
      final a = (v[i] * v[i] - v[i - 1] * v[i - 1]) / (2 * DriveSimulator.step);
      expect(a, lessThanOrEqualTo(2.0 + 1e-6));
      expect(a, greaterThanOrEqualTo(-3.0 - 1e-6));
    }
  });

  test('Tempolimit begrenzt das Tempo', () {
    final pts = straight(const RoutePoint(48, 9), 90, 5000, step: 50);
    final sim = DriveSimulator()
      ..setRoute(pts, limits: const [SpeedLimit(0, 5000, 50)]);
    expect(sim.profile.reduce(math.max) * 3.6, closeTo(50, 0.5));
  });

  test('faehrt die Route bis zum Ziel ab', () {
    final pts = hairpinRoute();
    final sim = DriveSimulator()..setRoute(pts);
    var t = 0;
    SimFix? f;
    while (!sim.finished && t < 2000) {
      f = sim.step1(1);
      t++;
    }
    expect(sim.finished, isTrue);
    expect(dist(f!.point, pts.last), lessThan(2));
    // 4 km mit Kehre: realistisch zwischen 3 und 6 Minuten.
    expect(t, inInclusiveRange(150, 360));
  });

  test('Verfahren: weg von der Route, neue Linie beendet die Abweichung', () {
    final pts = straight(const RoutePoint(48, 9), 90, 5000, step: 50);
    final sim = DriveSimulator()..setRoute(pts);
    for (var i = 0; i < 60; i++) {
      sim.step1(1);
    }
    sim.detour(lengthM: 300);
    for (var i = 0; i < 20; i++) {
      sim.step1(1);
    }
    final cum = cumulativeDistances(pts);
    final off = projectOnPolyline(sim.position!, pts, cum)!.distanceM;
    expect(off, greaterThan(100));
    // Navigation berechnet neu: Linie ab der jetzigen Position.
    final detour = [sim.position!, ...straight(sim.position!, 180, 1000, step: 50)];
    sim.setRoute(detour);
    expect(sim.detouring, isFalse);
    final f = sim.step1(1);
    expect(dist(f.point, detour.first), lessThan(30));
  });
}

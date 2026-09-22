import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/route_follow.dart';

import 'helpers.dart';

void main() {
  const home = RoutePoint(51.305, 7.355);

  test('lange Gerade mit wenigen Punkten: mittendrin NICHT abseits', () {
    // Nur Anfang und Ende - wie auf Landstrassen-Geraden ueblich.
    final end = destinationPoint(home, 90, 3000);
    final f = RouteFollower(
        RoutePlan(points: [home, end], distanceM: dist(home, end)));
    final onRoad = destinationPoint(destinationPoint(home, 90, 1500), 0, 8);
    final s = f.update(onRoad.lat, onRoad.lon)!;
    expect(s.isOffRoute, isFalse);
    expect(s.offRouteM, closeTo(8, 1));
    expect(s.remainingM, closeTo(1500, 10));
  });

  test('Rundtour: am Start 0 %, nicht 99 %', () {
    final loop = circle(destinationPoint(home, 90, 5000), 5000,
        n: 240, startAngle: 270);
    expect(dist(loop.first, home), lessThan(10));
    final f = RouteFollower(RoutePlan(points: loop, distanceM: pathLength(loop)));
    // Erster Fix 300 m vom Start weg - ausserhalb des Suchfensters.
    final p = destinationPoint(home, 180, 30);
    final s = f.update(p.lat, p.lon)!;
    expect(s.progress, lessThan(0.05));

    // Unterwegs: Fortschritt waechst.
    final mid = loop[120];
    final s2 = f.update(mid.lat, mid.lon)!;
    expect(s2.progress, closeTo(0.5, 0.02));

    // Zurueck am Start: jetzt ist es das Ende der Runde.
    final back = loop[238];
    final s3 = f.update(back.lat, back.lon)!;
    expect(s3.progress, greaterThan(0.95));
  });

  test('weit weg: Abstand in Metern', () {
    final line = straight(home, 0, 5000, step: 100);
    final f = RouteFollower(RoutePlan(points: line, distanceM: pathLength(line)));
    final away = destinationPoint(line[20], 90, 2500);
    final s = f.update(away.lat, away.lon)!;
    expect(s.isOffRoute, isTrue);
    expect(s.offRouteM, closeTo(2500, 30));
  });
}

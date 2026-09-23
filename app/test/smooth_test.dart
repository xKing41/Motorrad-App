import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/smooth_position.dart';

import 'helpers.dart';

const home = RoutePoint(51.2, 7.6);

void main() {
  test('zwischen zwei GPS-Messungen laeuft der Pfeil gleichmaessig weiter',
      () {
    final route = straight(home, 90, 5000, step: 50);
    final cum = cumulativeDistances(route);
    final tr = SmoothTracker();
    // Messung bei 1000 m, 25 m/s.
    tr.onFix(pointAlong(route, cum, 1000), 25, 90, 0, alongM: 1000);
    final shown = <double>[];
    for (var us = 0; us <= 1000000; us += 33000) {
      tr.frame(us, route: route, cum: cum);
      shown.add(tr.shownAlongM!);
    }
    // Stetig vorwaerts, am Ende nahe der vorhergesagten Stelle.
    for (var i = 1; i < shown.length; i++) {
      expect(shown[i], greaterThanOrEqualTo(shown[i - 1]));
      expect(shown[i] - shown[i - 1], lessThan(3));
    }
    expect(shown.last, closeTo(1025, 6));
  });

  test('neue Messung knapp dahinter: kein Ruecksprung', () {
    final route = straight(home, 90, 5000, step: 50);
    final cum = cumulativeDistances(route);
    final tr = SmoothTracker();
    tr.onFix(pointAlong(route, cum, 1000), 25, 90, 0, alongM: 1000);
    for (var us = 0; us <= 1500000; us += 33000) {
      tr.frame(us, route: route, cum: cum);
    }
    final before = tr.shownAlongM!;
    // Gebremst: Messung liegt 10 m hinter der Anzeige.
    tr.onFix(pointAlong(route, cum, before - 10), 5, 90, 1500000,
        alongM: before - 10);
    tr.frame(1533000, route: route, cum: cum);
    expect(tr.shownAlongM!, greaterThanOrEqualTo(before));
  });

  test('der Pfeil folgt der Route um die Kurve', () {
    // Erst nach Osten, dann nach Norden.
    final east = straight(home, 90, 1000, step: 20);
    final north = straight(east.last, 0, 1000, step: 20).skip(1);
    final route = [...east, ...north];
    final cum = cumulativeDistances(route);
    final tr = SmoothTracker();
    tr.onFix(pointAlong(route, cum, 900), 20, 90, 0, alongM: 900);
    for (var us = 0; us <= 2000000; us += 33000) {
      tr.frame(us, route: route, cum: cum);
    }
    // 900 + 2 s * 20 m/s = 940 m ... die Richtung dreht schon Richtung Norden.
    expect(tr.heading, lessThan(90));
    // Und der Pfeil bleibt auf der Linie.
    final hit = projectOnPolyline(tr.pos!, route, cum)!;
    expect(hit.distanceM, lessThan(1));
  });

  test('ohne Route: Weiterrechnen in Fahrtrichtung, hoechstens 2 s', () {
    final tr = SmoothTracker();
    tr.onFix(home, 20, 0, 0);
    for (var us = 0; us <= 5000000; us += 33000) {
      tr.frame(us);
    }
    final d = dist(home, tr.pos!);
    expect(d, closeTo(40, 3)); // 2 s * 20 m/s
  });

  test('Zoom nach Tempo', () {
    expect(SmoothTracker.zoomForSpeed(5), greaterThan(SmoothTracker.zoomForSpeed(35)));
  });
}

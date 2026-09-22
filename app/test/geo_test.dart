import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';

import 'helpers.dart';

void main() {
  group('Kurs und Zielpunkt', () {
    test('Kurs nach Norden und Osten', () {
      const a = RoutePoint(51.0, 7.0);
      expect(bearingDeg(a, const RoutePoint(51.1, 7.0)), closeTo(0, 0.01));
      expect(bearingDeg(a, const RoutePoint(51.0, 7.1)), closeTo(90, 0.1));
    });

    test('destinationPoint landet in Abstand und Richtung', () {
      const a = RoutePoint(51.3, 7.35);
      for (final brg in [0.0, 45.0, 135.0, 270.0]) {
        final b = destinationPoint(a, brg, 25000);
        expect(dist(a, b), closeTo(25000, 5));
        expect(angleDiff(bearingDeg(a, b), brg).abs(), lessThan(0.5));
      }
    });

    test('angleDiff normiert auf -180..180', () {
      expect(angleDiff(350, 10), closeTo(20, 1e-9));
      expect(angleDiff(10, 350), closeTo(-20, 1e-9));
      expect(angleDiff(0, 180), closeTo(180, 1e-9));
    });
  });

  group('Polyline', () {
    test('bekanntes Google-Beispiel (Praezision 5)', () {
      final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@', precision: 5);
      expect(pts.length, 3);
      expect(pts[0].lat, closeTo(38.5, 1e-6));
      expect(pts[0].lon, closeTo(-120.2, 1e-6));
      expect(pts[2].lat, closeTo(43.252, 1e-6));
      expect(pts[2].lon, closeTo(-126.453, 1e-6));
    });

    test('hin und zurueck mit Praezision 6', () {
      final pts = [
        const RoutePoint(51.312345, 7.341234),
        const RoutePoint(51.313001, 7.339999),
        const RoutePoint(-33.9, 151.2),
      ];
      final back = decodePolyline(encodePolyline(pts));
      expect(back.length, pts.length);
      for (var i = 0; i < pts.length; i++) {
        expect(back[i].lat, closeTo(pts[i].lat, 1e-6));
        expect(back[i].lon, closeTo(pts[i].lon, 1e-6));
      }
    });

    test('abgeschnittene Zeichenkette wirft nicht', () {
      final enc = encodePolyline(const [RoutePoint(51, 7), RoutePoint(52, 8)]);
      expect(() => decodePolyline(enc.substring(0, enc.length - 2)),
          returnsNormally);
    });
  });

  group('Verteilen und Projizieren', () {
    test('resample: gleichmaessige Abstaende', () {
      final line = straight(const RoutePoint(51, 7), 90, 1000, step: 400);
      final r = resample(line, 20);
      for (var i = 1; i < r.length - 1; i++) {
        expect(dist(r[i - 1], r[i]), closeTo(20, 0.5));
      }
      expect(pathLength(r), closeTo(pathLength(line), 1));
    });

    test('Abstand zur LINIE, nicht zum naechsten Stuetzpunkt', () {
      // Eine Gerade mit nur zwei Punkten, 4 km lang.
      const a = RoutePoint(51.0, 7.0);
      final b = destinationPoint(a, 90, 4000);
      final pts = [a, b];
      final cum = cumulativeDistances(pts);
      // Mitten auf der Strecke, 10 m daneben.
      final mid = destinationPoint(destinationPoint(a, 90, 2000), 0, 10);
      final hit = projectOnPolyline(mid, pts, cum)!;
      expect(hit.distanceM, closeTo(10, 1));
      expect(hit.alongM, closeTo(2000, 5));
    });

    test('pointAlong', () {
      final line = straight(const RoutePoint(51, 7), 0, 3000, step: 500);
      final cum = cumulativeDistances(line);
      final p = pointAlong(line, cum, 1250);
      expect(dist(line.first, p), closeTo(1250, 2));
    });
  });

  group('Kurvigkeit', () {
    test('Gerade ist nicht kurvig', () {
      final line = straight(const RoutePoint(51, 7), 30, 20000, step: 300);
      final c = curvatureOf(line);
      expect(c.index, lessThan(0.05));
      expect(c.bendsPerKm, lessThan(0.1));
    });

    test('Serpentinen sind deutlich kurviger als eine Landstrasse', () {
      final gentle = wiggly(const RoutePoint(51, 7), 0, 20000,
          amplitude: 60, wavelength: 2500);
      final twisty = wiggly(const RoutePoint(51, 7), 0, 20000,
          amplitude: 120, wavelength: 500);
      final g = curvatureOf(gentle);
      final t = curvatureOf(twisty);
      expect(t.index, greaterThan(g.index));
      expect(t.bendsPerKm, greaterThan(g.bendsPerKm));
      expect(t.curvyShare, greaterThan(0.2));
      expect(t.label, anyOf('hoch', 'sehr hoch'));
    });

    test('Dichte der Stuetzpunkte veraendert das Ergebnis kaum', () {
      final dense = wiggly(const RoutePoint(51, 7), 0, 15000,
          amplitude: 80, wavelength: 800, step: 5);
      final sparse = wiggly(const RoutePoint(51, 7), 0, 15000,
          amplitude: 80, wavelength: 800, step: 25);
      final a = curvatureOf(dense).index;
      final b = curvatureOf(sparse).index;
      expect((a - b).abs(), lessThan(0.15));
    });
  });

  group('Doppelt gefahren', () {
    test('Rundkurs ohne Ueberschneidung', () {
      final loop = circle(const RoutePoint(51, 7), 5000);
      expect(overlapShare(loop), lessThan(0.02));
    });

    test('Hin und auf demselben Weg zurueck', () {
      final out = straight(const RoutePoint(51, 7), 45, 8000, step: 100);
      final back = out.reversed.toList();
      final share = overlapShare([...out, ...back.skip(1)]);
      expect(share, greaterThan(0.8));
    });
  });

  group('Stichstrassen', () {
    test('Sackgasse mitten in der Runde wird herausgeschnitten', () {
      final loop = circle(const RoutePoint(51, 7), 4000, n: 360);
      // Bei einem Viertel: 1,2 km nach aussen und auf demselben Weg zurueck.
      final at = loop[90];
      final spurOut = straight(at, bearingDeg(const RoutePoint(51, 7), at),
          1200,
          step: 50);
      final spur = [...spurOut.skip(1), ...spurOut.reversed.skip(1)];
      final route = [...loop.sublist(0, 91), ...spur, ...loop.sublist(91)];

      final cut = removeSpurs(route);
      expect(cut.changed, isTrue);
      expect(cut.removedM, closeTo(2400, 150));
      expect(pathLength(cut.points), closeTo(pathLength(loop), 100));
      // Die Zuordnung alter zu neuer Indizes stimmt.
      expect(cut.indexMap[0], 0);
      expect(cut.indexMap[91 + 5], -1);
      expect(cut.points[cut.indexMap.last], route.last);
    });

    test('Zwischenstopp am Ende der Sackgasse bleibt erhalten', () {
      final loop = circle(const RoutePoint(51, 7), 4000, n: 360);
      final at = loop[90];
      final spurOut = straight(at, bearingDeg(const RoutePoint(51, 7), at),
          800,
          step: 50);
      final spur = [...spurOut.skip(1), ...spurOut.reversed.skip(1)];
      final route = [...loop.sublist(0, 91), ...spur, ...loop.sublist(91)];
      final cut = removeSpurs(route, keep: [spurOut.last]);
      expect(cut.changed, isFalse);
    });

    test('Die Rundtour selbst wird nie weggeschnitten', () {
      final loop = circle(const RoutePoint(51, 7), 700, n: 120);
      final cut = removeSpurs(loop);
      expect(cut.changed, isFalse);
    });

    test('Lolli (Stiel mit Schleife am Ende) wird nicht zerschnitten', () {
      const s = RoutePoint(51, 7);
      final stick = straight(s, 0, 1500, step: 50);
      final ring = circle(
          destinationPoint(stick.last, 0, 700), 700,
          n: 120, startAngle: 180);
      final route = [...stick, ...ring.skip(1), ...stick.reversed.skip(1)];
      final cut = removeSpurs(route);
      // Ein Stiel mit echter Schleife ist kein reines Hin-und-zurueck.
      expect(cut.changed, isFalse);
    });
  });
}

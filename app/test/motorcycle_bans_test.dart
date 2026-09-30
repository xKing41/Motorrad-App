import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/motorcycle_bans.dart';
import 'package:schraeglage/services/road_check.dart';

import 'helpers.dart';

void main() {
  group('Tags lesen', () {
    test('Motorradverbot, auch zeitweise (wie L 701 Priorei)', () {
      expect(MotorcycleBans.label({'motorcycle': 'no'}), 'Motorradverbot');
      expect(
          MotorcycleBans.label({
            'motorcycle:conditional': 'no @ (Mo-Fr 15:00-22:00; Sa,Su,PH)',
          }),
          'Motorradverbot (Mo-Fr 15:00-22:00; Sa,Su,PH)');
      expect(
          MotorcycleBans.label(
              {'motor_vehicle:conditional': 'no @ (Sa,Su,PH 10:00-20:00)'}),
          'Motorradverbot (Sa,Su,PH 10:00-20:00)');
    });

    test('Anlieger, Landwirtschaft, Privat', () {
      expect(MotorcycleBans.label({'motor_vehicle': 'destination'}),
          'nur Anlieger');
      expect(MotorcycleBans.label({'motor_vehicle': 'agricultural;forestry'}),
          'nur Land-/Forstwirtschaft');
      expect(MotorcycleBans.label({'access': 'private'}), 'Privatweg');
    });

    test('Ausnahme fuer Motorraeder gilt', () {
      expect(
          MotorcycleBans.label({'motor_vehicle': 'no', 'motorcycle': 'yes'}),
          isNull);
      expect(MotorcycleBans.label({'access': 'no', 'motor_vehicle': 'yes'}),
          isNull);
      // Fuer Motorraeder frei, aber zeitweise gesperrt.
      expect(
          MotorcycleBans.label({
            'motorcycle': 'yes',
            'motorcycle:conditional': 'no @ (Su)',
          }),
          'Motorradverbot (Su)');
      expect(MotorcycleBans.label({'highway': 'secondary'}), isNull);
      expect(MotorcycleBans.label({'motorcycle:conditional': 'yes @ (Su)'}),
          isNull);
    });

    test('Abfrage: nur Wege, alle Tag-Varianten, Ausnahmen beachtet', () {
      final q = MotorcycleBans.query(straight(const RoutePoint(51.3, 7.4), 0, 5000));
      expect(q, contains('"motorcycle:conditional"'));
      expect(q, contains('["motorcycle"!~"^(yes|designated|permissive)\$"]'));
      expect(q, contains('out tags geom'));
      expect(q, contains('around:120'));
    });
  });

  group('Abgleich mit der Route', () {
    const a = RoutePoint(51.30, 7.40);
    final route = straight(a, 0, 6000); // 6 km nach Norden
    final cum = cumulativeDistances(route);

    BannedWay way(double fromM, double toM, String label,
            {double offsetM = 0}) =>
        BannedWay(1, [
          destinationPoint(pointAlong(route, cum, fromM), 90, offsetM),
          destinationPoint(pointAlong(route, cum, toM), 90, offsetM),
        ], label);

    test('gesperrtes Stueck auf der Route wird gefunden', () {
      final l = MotorcycleBans.match(
          route, [way(2000, 4000, 'Motorradverbot (Sa,Su,PH)')]);
      expect(l, hasLength(1));
      expect(l.single.kind, 'Motorradverbot (Sa,Su,PH)');
      expect(l.single.fromM, closeTo(2000, 25));
      expect(l.single.toM, closeTo(4000, 25));
    });

    test('Kreuzung und Parallelstrasse zaehlen nicht', () {
      final mid = pointAlong(route, cum, 3000);
      final crossing = BannedWay(2, [
        destinationPoint(mid, 270, 300),
        destinationPoint(mid, 90, 300),
      ], 'Motorradverbot');
      final parallel = way(1000, 5000, 'nur Anlieger', offsetM: 15);
      expect(MotorcycleBans.match(route, [crossing, parallel]), isEmpty);
    });

    test('Abfrage ueber Overpass (Test-Antwort)', () async {
      final b = MotorcycleBans(fetch: (q) async => {
            'elements': [
              {
                'type': 'way',
                'id': 42,
                'tags': {
                  'highway': 'secondary',
                  'ref': 'L 701',
                  'motorcycle:conditional': 'no @ (Sa,Su,PH)',
                },
                'geometry': [
                  for (final m in [1000.0, 1500.0, 2000.0, 2500.0])
                    {
                      'lat': pointAlong(route, cum, m).lat,
                      'lon': pointAlong(route, cum, m).lon,
                    },
                ],
              },
            ],
          });
      final l = await b.check(route);
      expect(l.single.kind, 'Motorradverbot (Sa,Su,PH)');
      expect(l.single.lengthM, closeTo(1500, 40));
    });

    test('Overpass nicht erreichbar: Fehler (Tour gilt als ungeprueft)',
        () async {
      final b = MotorcycleBans(fetch: (q) async => null);
      expect(() => b.check(route), throwsA(anything));
      // Zusammen mit einer funktionierenden Pruefung: die zaehlt.
      final c = CombinedRoadCheck([b, _Fixed()]);
      expect((await c.check(route)).single.kind, 'Feldweg');
    });
  });

  group('Zwischenspeicher', () {
    test('dieselbe Gegend nur einmal abfragen, Neues nur fuer das Neue',
        () async {
      final queries = <String>[];
      final b = MotorcycleBans(fetch: (q) async {
        queries.add(q);
        return {'elements': []};
      });
      const a = RoutePoint(51.30, 7.40);
      final r1 = straight(a, 0, 20000);
      await b.check(r1);
      await b.check(r1); // Navistart: gleiche Tour
      expect(queries, hasLength(1));
      // Neue Tour, erste Haelfte gleich: nur der neue Teil wird gefragt.
      final r2 = [...straight(a, 0, 10000), ...straight(r1[100], 90, 10000)];
      expect(b.uncovered(r2), hasLength(1));
      await b.check(r2);
      expect(queries, hasLength(2));
      expect(b.uncovered(r2), isEmpty);
    });

    test('Suchkorridor folgt den Kurven (nicht grob abgeschnitten)', () {
      // Serpentinen: 30 Kehren auf 3 km.
      const a = RoutePoint(51.3, 7.4);
      final pts = <RoutePoint>[a];
      for (var i = 0; i < 30; i++) {
        pts.add(destinationPoint(pts.last, i.isEven ? 60 : 300, 200));
      }
      final simple = simplifyPath(pts, 30);
      // Jede Kehre bleibt drin - sonst laege die Strasse ausserhalb.
      expect(simple.length, pts.length);
      final straightLine = straight(a, 0, 5000);
      expect(simplifyPath(straightLine, 30), hasLength(2));
    });
  });
}

class _Fixed extends RoadCheck {
  @override
  Future<List<RoadIssue>> check(List<RoutePoint> pts,
          {bool unpaved = true}) async =>
      const [RoadIssue(100, 900, 'Feldweg')];
}

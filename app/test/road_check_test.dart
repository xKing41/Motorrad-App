import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/road_check.dart';
import 'package:schraeglage/services/route_planner.dart';
import 'package:schraeglage/services/routing_engine.dart';

import 'helpers.dart';

/// Meldet in jeder Route ein Stueck Feldweg in der Mitte - die ersten
/// [badCalls] Male.
class FakeRoadCheck implements RoadCheck {
  FakeRoadCheck({this.badCalls = 1});
  final int badCalls;
  int calls = 0;

  @override
  Future<List<RoadIssue>> check(List<RoutePoint> pts,
      {bool unpaved = true}) async {
    calls++;
    if (calls > badCalls) return const [];
    final total = pathLength(pts);
    return [RoadIssue(total * 0.4, total * 0.4 + 800, 'Feldweg')];
  }
}

void main() {
  const home = RoutePoint(51.39, 7.33);

  group('Antwort lesen', () {
    final line = straight(home, 90, 1000); // 10 Stuecke a 100 m
    Map<String, dynamic> answer(List<Map<String, dynamic>> edges) => {
          'shape': encodePolyline(line),
          'edges': edges,
        };

    test('Feldweg und Schotter werden gefunden, Strasse nicht', () {
      final j = answer([
        {'use': 'road', 'surface': 'paved_smooth', 'begin_shape_index': 0, 'end_shape_index': 3},
        {'use': 'track', 'surface': 'paved', 'begin_shape_index': 3, 'end_shape_index': 5},
        {'use': 'road', 'surface': 'gravel', 'unpaved': true, 'begin_shape_index': 5, 'end_shape_index': 7},
        {'use': 'road', 'surface': 'paved', 'begin_shape_index': 7, 'end_shape_index': 10},
      ]);
      final l = ValhallaRoadCheck.merge(ValhallaRoadCheck.parse(j, 0, 1000));
      // Feldweg (auch asphaltiert!) und Schotter grenzen aneinander.
      expect(l, hasLength(1));
      expect(l.single.kind, 'Feldweg');
      expect(l.single.fromM, closeTo(300, 5));
      expect(l.single.toM, closeTo(700, 5));
    });

    test('Schotter erlaubt: nur noch Feldweg/Fussweg zaehlt', () {
      expect(ValhallaRoadCheck.classify({'use': 'road', 'surface': 'gravel'},
          unpaved: false), isNull);
      expect(ValhallaRoadCheck.classify({'use': 'track'}, unpaved: false),
          'Feldweg');
      expect(ValhallaRoadCheck.classify({'use': 'cycleway'}), 'Radweg');
      expect(ValhallaRoadCheck.classify({'use': 'road', 'surface': 'impassable'},
          unpaved: false), 'unbefestigt');
      expect(ValhallaRoadCheck.classify({'use': 'road', 'surface': 'paved_rough'}),
          isNull);
      // Zufahrten (Tankstelle, Parkplatz) sind kein Problem.
      expect(ValhallaRoadCheck.classify({'use': 'driveway'}), isNull);
    });

    test('Start, Ziel, Stopps und Kurzes zaehlen nicht', () {
      final pts = straight(home, 90, 20000);
      final cum = cumulativeDistances(pts);
      final stop = pointAlong(pts, cum, 10000);
      final l = relevantIssues([
        const RoadIssue(0, 250, 'Feldweg'), // Hofeinfahrt am Start
        const RoadIssue(5000, 5020, 'Feldweg'), // Zuordnungsrauschen
        const RoadIssue(9950, 10100, 'unbefestigt'), // Tankstelle
        const RoadIssue(14000, 15000, 'Feldweg'), // echt
        const RoadIssue(19850, 20000, 'Feldweg'), // am Ziel
      ], pts, keepNear: [stop]);
      expect(l.map((i) => i.fromM), [14000]);
      // Meiden: auf 1 km verteilt mehrere Punkte.
      expect(issueAvoidPoints(l, pts), hasLength(2));
    });
  });

  group('Server', () {
    test('fragt mit Motorrad-Profil, faellt auf Auto zurueck', () async {
      final seen = <String>[];
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map;
        seen.add(body['costing'] as String);
        if (body['costing'] == 'motorcycle') {
          return http.Response('{"error_code":125}', 400);
        }
        final line = decodePolyline(body['encoded_polyline'] as String);
        return http.Response(
            jsonEncode({
              'shape': encodePolyline(line),
              'edges': [
                {'use': 'footway', 'begin_shape_index': 0, 'end_shape_index': line.length - 1},
              ],
            }),
            200);
      });
      final check = ValhallaRoadCheck(
          base: 'https://example.org', client: client, minInterval: Duration.zero);
      final l = await check.check(straight(home, 0, 2000));
      expect(seen, ['motorcycle', 'auto']);
      expect(l.single.kind, 'Fußweg');
      expect(l.single.lengthM, closeTo(2000, 30));
    });
  });

  group('Planer', () {
    RouteRequest loop() => RouteRequest(
          startLat: home.lat,
          startLon: home.lon,
          distanceKm: 60,
          roundTrip: true,
        );

    test('Feldweg gefunden: ohne ihn neu gerechnet, keine Warnung', () async {
      final engine = FakeEngine();
      final check = FakeRoadCheck(badCalls: 1);
      final plan = await TourPlanner(engine,
              random: math.Random(4), maxVariants: 1, roadCheck: check)
          .plan(loop());
      expect(engine.prefsSeen.last.avoid, isNotEmpty);
      expect(plan.notes.where((n) => n.startsWith('Achtung')), isEmpty);
    });

    test('nicht zu vermeiden: Warnung mit Stelle, hoechstens 2 Versuche',
        () async {
      final engine = FakeEngine();
      final check = FakeRoadCheck(badCalls: 1000);
      final plan = await TourPlanner(engine,
              random: math.Random(4), maxVariants: 1, roadCheck: check)
          .plan(loop());
      final warn = plan.notes.singleWhere((n) => n.startsWith('Achtung'));
      expect(warn, contains('800 m Feldweg'));
      // 1 Pruefung + erster Versuch; der bringt nichts -> Schluss.
      expect(check.calls, 2);
    });

    test('ohne Netz fuer die Pruefung: Tour trotzdem', () async {
      final plan = await TourPlanner(FakeEngine(),
              random: math.Random(4), maxVariants: 1, roadCheck: _Failing())
          .plan(loop());
      expect(plan.points, isNotEmpty);
    });
  });

  test('Valhalla-Anfrage: Belag und Feldwege nie "egal"', () {
    final e = ValhallaEngine();
    for (final c in Curviness.values) {
      for (final unpaved in [true, false]) {
        final req = e.buildRequest([
          const Waypoint(home, WaypointKind.endpoint),
          Waypoint(destinationPoint(home, 90, 5000), WaypointKind.endpoint),
        ], RoutingPrefs(curviness: c, avoidUnpaved: unpaved));
        final o = (req['costing_options'] as Map)['motorcycle'] as Map;
        expect(o['use_trails'] as double, lessThan(0.4), reason: '$c');
        expect(o['use_tracks'] as double, lessThan(0.5), reason: '$c');
      }
    }
  });
}

class _Failing implements RoadCheck {
  @override
  Future<List<RoadIssue>> check(List<RoutePoint> pts, {bool unpaved = true}) =>
      Future.error(http.ClientException('offline'));
}

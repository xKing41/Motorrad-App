import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/routing_engine.dart';

void main() {
  const a = RoutePoint(51.30, 7.35);
  const b = RoutePoint(51.40, 7.50);
  const c = RoutePoint(51.35, 7.60);

  group('Valhalla-Anfrage', () {
    final engine = ValhallaEngine();

    test('Hilfspunkte: through + Strassenklassen-Filter, Enden: break', () {
      final req = engine.buildRequest([
        const Waypoint(a, WaypointKind.endpoint),
        const Waypoint(b, WaypointKind.shape),
        const Waypoint(c, WaypointKind.stop),
        const Waypoint(a, WaypointKind.endpoint),
      ], const RoutingPrefs(curviness: Curviness.curvy));

      final locs = (req['locations'] as List).cast<Map<String, dynamic>>();
      expect(locs.map((l) => l['type']).toList(),
          ['break', 'through', 'break', 'break']);
      final filter = locs[1]['search_filter'] as Map;
      expect(filter['min_road_class'], 'tertiary');
      expect(filter['max_road_class'], 'primary');
      expect(locs[2].containsKey('search_filter'), isFalse);

      expect(req['costing'], 'motorcycle');
      final opts = (req['costing_options'] as Map)['motorcycle'] as Map;
      expect(opts['use_highways'], 0.0);
      expect(opts['use_trails'], greaterThan(0.3));
      expect(opts['exclude_unpaved'], isTrue);
      expect(req.containsKey('alternates'), isFalse);
      // Muss sich als JSON verschicken lassen.
      expect(() => jsonEncode(req), returnsNormally);
    });

    test('entspannte Wiederholung ohne Filter', () {
      final req = engine.buildRequest([
        const Waypoint(a, WaypointKind.endpoint),
        const Waypoint(b, WaypointKind.shape),
        const Waypoint(c, WaypointKind.endpoint),
      ], const RoutingPrefs(), relaxed: true);
      final loc = (req['locations'] as List)[1] as Map;
      expect(loc['type'], 'via');
      expect(loc.containsKey('search_filter'), isFalse);
    });

    test('Alternativen nur bei zwei Punkten', () {
      final req = engine.buildRequest([
        const Waypoint(a, WaypointKind.endpoint),
        const Waypoint(c, WaypointKind.endpoint),
      ], const RoutingPrefs(curviness: Curviness.direct, avoidMotorways: false),
          alternates: 2);
      expect(req['alternates'], 2);
      final opts = (req['costing_options'] as Map)['motorcycle'] as Map;
      expect(opts['use_highways'], 1.0);
    });

    test('oeffentlicher Server: gedrosselt und nacheinander', () {
      final pub = ValhallaEngine();
      expect(pub.parallelRequests, 1);
      expect(pub.minInterval.inMilliseconds, greaterThanOrEqualTo(1000));
      final own = ValhallaEngine(baseUrl: 'http://192.168.1.5:8002');
      expect(own.minInterval, Duration.zero);
      expect(own.parallelRequests, greaterThan(1));
    });

    test('URL wird bereinigt', () {
      expect(ValhallaEngine.normalizeUrl(null), ValhallaEngine.publicUrl);
      expect(ValhallaEngine.normalizeUrl(' https://x.de/route/ '), 'https://x.de');
    });
  });

  group('Valhalla-Antwort', () {
    Map<String, dynamic> trip(List<List<RoutePoint>> legs, {String units = 'kilometers'}) => {
          'trip': {
            'units': units,
            'legs': [
              for (final l in legs)
                {
                  'shape': encodePolyline(l),
                  'maneuvers': [
                    {'instruction': 'Los', 'length': 1.0, 'begin_shape_index': 0},
                    {'instruction': 'Weiter', 'length': 2.0, 'begin_shape_index': 1},
                  ],
                },
            ],
            'summary': {'length': 12.5, 'time': 900},
          },
        };

    test('Abschnitte werden ohne doppelte Punkte verbunden', () {
      final routes = ValhallaEngine.parseResponse(trip([
        [a, b],
        [b, c],
      ]));
      final r = routes.single;
      expect(r.points.length, 3);
      expect(r.distanceM, closeTo(12500, 1e-6));
      expect(r.durationSec, 900);
      // Anweisung des zweiten Abschnitts zeigt auf den richtigen Punkt.
      expect(r.steps.map((s) => s.pointIndex).toList(), [0, 1, 1, 2]);
    });

    test('Meilen werden umgerechnet', () {
      final r = ValhallaEngine.parseResponse(trip([
        [a, b],
      ], units: 'miles')).single;
      expect(r.distanceM, closeTo(12.5 * 1609.344, 1e-6));
    });

    test('Alternativen werden mitgeliefert', () {
      final data = trip([
        [a, c],
      ]);
      data['alternates'] = [trip([
        [a, b, c],
      ])];
      expect(ValhallaEngine.parseResponse(data).length, 2);
    });
  });

  group('Valhalla-Fehler', () {
    test('Kein Weg: zweiter Versuch ohne Filter', () async {
      var n = 0;
      final bodies = <Map<String, dynamic>>[];
      final client = MockClient((req) async {
        n++;
        bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
        if (n == 1) {
          return http.Response(
              jsonEncode({'error_code': 442, 'error': 'No path could be found'}),
              400);
        }
        return http.Response(
            jsonEncode({
              'trip': {
                'legs': [
                  {'shape': encodePolyline(const [a, b, c]), 'maneuvers': []},
                ],
                'summary': {'length': 20.0, 'time': 1200},
              },
            }),
            200);
      });
      final engine = ValhallaEngine(client: client, minInterval: Duration.zero);
      final r = await engine.route([
        const Waypoint(a, WaypointKind.endpoint),
        const Waypoint(b, WaypointKind.shape),
        const Waypoint(c, WaypointKind.endpoint),
      ], const RoutingPrefs());
      expect(n, 2);
      expect(r.single.points.length, 3);
      expect(((bodies[1]['locations'] as List)[1] as Map)['type'], 'via');
    });

    test('Server ohne Motorrad-Profil: weiter mit Auto-Profil', () async {
      final costings = <String>[];
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        costings.add(body['costing'] as String);
        if (body['costing'] == 'motorcycle') {
          return http.Response(
              jsonEncode({'error_code': 125, 'error': 'No costing method found'}),
              400);
        }
        return http.Response(
            jsonEncode({
              'trip': {
                'legs': [
                  {'shape': encodePolyline(const [a, c]), 'maneuvers': []},
                ],
                'summary': {'length': 20.0, 'time': 1200},
              },
            }),
            200);
      });
      final engine = ValhallaEngine(
          baseUrl: 'https://ohne-motorrad.example',
          client: client,
          minInterval: Duration.zero);
      const wps = [
        Waypoint(a, WaypointKind.endpoint),
        Waypoint(c, WaypointKind.endpoint),
      ];
      await engine.route(wps, const RoutingPrefs());
      await engine.route(wps, const RoutingPrefs());
      // Beim zweiten Mal gleich mit dem Auto-Profil.
      expect(costings, ['motorcycle', 'auto', 'auto']);
    });

    test('Server ueberlastet: verstaendliche Meldung', () async {
      final engine = ValhallaEngine(
          client: MockClient((_) async => http.Response('busy', 429)),
          minInterval: Duration.zero);
      expect(
        () => engine.route([
          const Waypoint(a, WaypointKind.endpoint),
          const Waypoint(c, WaypointKind.endpoint),
        ], const RoutingPrefs()),
        throwsA(isA<RouteException>().having(
            (e) => e.message, 'message', contains('ausgelastet'))),
      );
    });
  });

  group('GraphHopper', () {
    test('Custom Model hebt nie ueber 1 an', () {
      for (final c in Curviness.values) {
        final m = GraphHopperEngine.customModel(RoutingPrefs(curviness: c));
        for (final rule in (m['priority'] as List).cast<Map>()) {
          expect(double.parse(rule['multiply_by'] as String), lessThanOrEqualTo(1.0));
        }
      }
    });

    test('Antwort wird gelesen', () async {
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map;
        expect(body['profile'], 'car');
        expect((body['points'] as List).length, 2);
        return http.Response(
            jsonEncode({
              'paths': [
                {
                  'distance': 1234.0,
                  'time': 60000,
                  'points': {
                    'coordinates': [
                      [a.lon, a.lat],
                      [c.lon, c.lat],
                    ],
                  },
                  'instructions': [
                    {'text': 'Los', 'distance': 10, 'interval': [0, 1]},
                  ],
                },
              ],
            }),
            200);
      });
      final r = await GraphHopperEngine(baseUrl: 'https://gh.example/', client: client)
          .route([
        const Waypoint(a, WaypointKind.endpoint),
        const Waypoint(c, WaypointKind.endpoint),
      ], const RoutingPrefs());
      expect(r.single.distanceM, 1234);
      expect(r.single.durationSec, 60);
      expect(r.single.points.length, 2);
    });
  });
}

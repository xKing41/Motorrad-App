import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/traffic_service.dart';
import 'package:schraeglage/services/traffic_sources.dart';

import 'helpers.dart';

const home = RoutePoint(51.2, 7.6);

void main() {
  final route = straight(home, 90, 30000, step: 100);
  final cum = cumulativeDistances(route);
  RoutePoint at(double m) => pointAlong(route, cum, m);

  test('Autobahnen aus den Anweisungen erkennen', () {
    final roads = AutobahnTraffic.roadsIn([
      RouteStep(text: 'Fahren Sie auf A 45/E 41 Richtung Frankfurt.',
          distanceM: 0, pointIndex: 0),
      RouteStep(text: 'Wechseln Sie auf die A1.', distanceM: 0, pointIndex: 0),
      RouteStep(text: 'Biegen Sie rechts ab auf B 54.', distanceM: 0, pointIndex: 0),
    ]);
    expect(roads, {'A45', 'A1'});
  });

  test('Autobahn GmbH: Sperrung, Baustelle mit Vollsperrung, Stau', () {
    final geom = {
      'type': 'LineString',
      'coordinates': [
        [at(5000).lon, at(5000).lat],
        [at(5600).lon, at(5600).lat],
      ],
    };
    final closure = AutobahnTraffic.parse({
      'closure': [
        {'identifier': 'c1', 'title': 'A45 | AS Lüdenscheid', 'geometry': geom},
      ]
    }, 'closure', 'A45');
    expect(closure.single.category, TrafficCategory.closed);
    expect(closure.single.source, 'Autobahn GmbH');
    final works = AutobahnTraffic.parse({
      'roadworks': [
        {'identifier': 'r1', 'isBlocked': 'true', 'geometry': geom},
        {
          'identifier': 'r2',
          'isBlocked': 'false',
          'coordinate': {'lat': '51.2', 'long': '7.61'}
        },
      ]
    }, 'roadworks', 'A45');
    expect(works.map((i) => i.category),
        [TrafficCategory.closed, TrafficCategory.roadworks]);
    final jam = AutobahnTraffic.parse({
      'warning': [
        {'identifier': 'w1', 'delayTimeValue': '20', 'geometry': geom},
      ]
    }, 'warning', 'A45');
    expect(jam.single.category, TrafficCategory.jam);
    expect(jam.single.delaySec, 1200);
    expect(jam.single.isSevere, isTrue);
  });

  test('HERE: Meldungen werden gelesen', () {
    final list = HereTraffic.parse({
      'results': [
        {
          'location': {
            'length': 600,
            'shape': {
              'links': [
                {
                  'points': [
                    {'lat': at(8000).lat, 'lng': at(8000).lon},
                    {'lat': at(8600).lat, 'lng': at(8600).lon},
                  ]
                }
              ]
            }
          },
          'incidentDetails': {
            'id': 'h1',
            'type': 'construction',
            'roadClosed': true,
            'criticality': 'major',
            'description': {'value': 'Vollsperrung'},
          }
        }
      ]
    });
    expect(list.single.category, TrafficCategory.closed);
    expect(list.single.source, 'HERE');
    expect(list.single.description, 'Vollsperrung');
  });

  test('dieselbe Sperrung aus zwei Quellen erscheint einmal', () {
    TrafficIncident inc(String id, TrafficCategory c, double a, double b,
            String src, {int delay = 0}) =>
        TrafficIncident(
            id: id,
            category: c,
            points: [at(a), at(b)],
            alongM: a,
            endAlongM: b,
            source: src,
            delaySec: delay);
    final merged = TrafficHub.merge([
      inc('t', TrafficCategory.closed, 5000, 5600, 'TomTom'),
      inc('a', TrafficCategory.roadworks, 5100, 5500, 'Autobahn GmbH'),
      inc('j1', TrafficCategory.jam, 12000, 13000, 'TomTom', delay: 300),
      inc('j2', TrafficCategory.jam, 12200, 13100, 'HERE', delay: 480),
      inc('x', TrafficCategory.jam, 20000, 20500, 'HERE'),
    ]);
    expect(merged.length, 3);
    expect(merged[0].isClosure, isTrue);
    expect(merged[0].source, 'TomTom + Autobahn GmbH');
    expect(merged[1].delaySec, 480);
  });

  test('Hub: faellt eine Quelle aus, kommen die anderen trotzdem', () async {
    final geom = {
      'type': 'LineString',
      'coordinates': [
        [at(5000).lon, at(5000).lat],
        [at(5600).lon, at(5600).lat],
      ],
    };
    final autobahn = AutobahnTraffic(
        client: MockClient((req) async {
      if (req.url.path.endsWith('/closure')) {
        return http.Response(
            jsonEncode({
              'closure': [
                {'identifier': 'c9', 'geometry': geom}
              ]
            }),
            200);
      }
      return http.Response(jsonEncode({}), 200);
    }));
    final tomtom = TrafficService('KEY',
        client: MockClient((_) async => http.Response('nope', 403)));
    final hub = TrafficHub([tomtom, autobahn]);
    final list = await hub.alongRoute(route, steps: [
      RouteStep(text: 'Auf A 99 weiter', distanceM: 0, pointIndex: 0),
    ]);
    expect(list, isNotNull);
    expect(list!.single.isClosure, isTrue);
    expect(hub.lastError, contains('TomTom'));
  });
}

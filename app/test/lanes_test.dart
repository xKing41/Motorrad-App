import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/lanes.dart';
import 'package:schraeglage/services/navigation.dart';
import 'package:schraeglage/services/routing_engine.dart';

import 'helpers.dart';

void main() {
  test('turn:lanes lesen', () {
    expect(parseTurnLanes('left|through|through;right'), [
      {'left'},
      {'through'},
      {'through', 'right'},
    ]);
    expect(parseTurnLanes('|slight_right'), [
      {'none'},
      {'slight_right'},
    ]);
  });

  test('Empfehlung und Ansage', () {
    final lanes = parseTurnLanes('through|through|slight_right');
    final exit = recommendLanes(lanes, ManeuverType.exitRight)!;
    expect(exit.lanes.map((l) => l.recommended), [false, false, true]);
    expect(exit.spoken, 'die rechte Spur');

    final left = recommendLanes(
        parseTurnLanes('left|left|through|through;right'), ManeuverType.left)!;
    expect(left.spoken, 'die beiden linken Spuren');

    final straight = recommendLanes(
        parseTurnLanes('left|through|through|right'), ManeuverType.stayStraight)!;
    expect(straight.spoken, 'die mittleren Spuren');

    // Alle Spuren passen: keine Empfehlung noetig.
    expect(recommendLanes(parseTurnLanes('through|through'),
            ManeuverType.stayStraight)!
        .useful, isFalse);
    // Nichts passt (Daten widersprechen der Route): nichts anzeigen.
    expect(recommendLanes(parseTurnLanes('left|through'), ManeuverType.right),
        isNull);
  });

  group('Zuordnung zur Route', () {
    // Route nach Osten, Ausfahrt rechts bei 2 km.
    final route = straight(const RoutePoint(51.0, 7.0), 90, 3000, step: 50);
    final steps = [
      RouteStep(text: 'Los', distanceM: 0, pointIndex: 0, type: ManeuverType.start),
      RouteStep(text: 'Ausfahrt', distanceM: 0, pointIndex: 40, type: ManeuverType.exitRight),
      RouteStep(text: 'Ziel', distanceM: 0, pointIndex: route.length - 1,
          type: ManeuverType.destination),
    ];

    Map<String, dynamic> way(List<RoutePoint> geom, Map<String, dynamic> tags) => {
          'type': 'way',
          'tags': tags,
          'geometry': [for (final p in geom) {'lat': p.lat, 'lon': p.lon}],
        };

    test('nur fuer Abbiegungen, 40 m davor', () {
      final pts = OverpassLanes.approachPoints(route, steps);
      expect(pts.length, 1);
      expect(pts.single.$1, 1);
      final cum = cumulativeDistances(route);
      expect(dist(pts.single.$2, pointAlong(route, cum, 1960)), lessThan(1));
      expect(OverpassLanes.buildQuery(pts), contains('[~"^turn:lanes"~"."]'));
    });

    test('Richtung zaehlt: forward/backward und Einbahnstrasse', () {
      final pts = OverpassLanes.approachPoints(route, steps);
      final cum = cumulativeDistances(route);
      final geom = [pointAlong(route, cum, 1800), pointAlong(route, cum, 2000)];
      // Zweirichtungsstrasse, in Fahrtrichtung gezeichnet.
      var m = OverpassLanes.match({
        'elements': [
          way(geom, {
            'highway': 'primary',
            'turn:lanes:forward': 'through|through|right',
            'turn:lanes:backward': 'left|through',
          }),
        ],
      }, pts, steps);
      expect(m[1]!.spoken, 'die rechte Spur');
      // Dieselbe Strasse, gegen die Fahrtrichtung gezeichnet.
      m = OverpassLanes.match({
        'elements': [
          way(geom.reversed.toList(), {
            'highway': 'primary',
            'turn:lanes:forward': 'left|through',
            'turn:lanes:backward': 'through|slight_right',
          }),
        ],
      }, pts, steps);
      expect(m[1]!.spoken, 'die rechte Spur');
      // Einbahnstrasse in Gegenrichtung: gehoert nicht zur Route.
      m = OverpassLanes.match({
        'elements': [
          way(geom.reversed.toList(), {
            'highway': 'motorway',
            'turn:lanes': 'through|through|slight_right',
          }),
        ],
      }, pts, steps);
      expect(m, isEmpty);
    });

    test('Navigation zeigt die Spuren ab 1,5 km und sagt sie an', () async {
      final said = <String>[];
      final nav = NavigationSession(
        plan: RoutePlan(points: route, distanceM: 3000, steps: steps),
        engine: FakeEngine(),
        prefs: const RoutingPrefs(),
        lanes: _Fixed({
          1: recommendLanes(
              parseTurnLanes('through|through|slight_right'), ManeuverType.exitRight)!,
        }),
        speak: said.add,
      );
      await Future<void>.delayed(Duration.zero);
      final cum = cumulativeDistances(route);
      var p = pointAlong(route, cum, 300);
      nav.update(p.lat, p.lon, speedMs: 25);
      expect(nav.nextLanes, isNull); // 1,7 km vorher
      p = pointAlong(route, cum, 1100);
      nav.update(p.lat, p.lon, speedMs: 25);
      expect(nav.nextLanes, isNotNull);
      // Spur wird bei der letzten Vorwarnung (500 m) mit angesagt.
      p = pointAlong(route, cum, 1600);
      nav.update(p.lat, p.lon, speedMs: 25);
      expect(said.any((t) => t.endsWith('Ausfahrt rechts, rechte Spur.')), isTrue,
          reason: said.join(' | '));
    });
  });
}

class _Fixed implements LaneSource {
  _Fixed(this.m);
  final Map<int, LaneInfo> m;
  @override
  Future<Map<int, LaneInfo>> forRoute(
          List<RoutePoint> pts, List<RouteStep> steps) async =>
      m;
}

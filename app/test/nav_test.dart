import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/external_nav.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/navigation.dart';
import 'package:schraeglage/services/route_patch.dart';
import 'package:schraeglage/services/routing_engine.dart';
import 'package:schraeglage/services/traffic_service.dart';

import 'helpers.dart';

const home = RoutePoint(51.2, 7.6);

EngineRoute lineRoute(double km, {double brg = 90}) {
  final pts = straight(home, brg, km * 1000, step: 100);
  final n = pts.length;
  return EngineRoute(
    points: pts,
    distanceM: km * 1000,
    durationSec: (km * 60).round(),
    steps: [
      RouteStep(text: 'Los', distanceM: 0, pointIndex: 0, type: ManeuverType.start),
      RouteStep(text: 'Links', distanceM: 0, pointIndex: n ~/ 2, type: ManeuverType.left),
      RouteStep(
          text: 'Ziel', distanceM: 0, pointIndex: n - 1, type: ManeuverType.destination),
    ],
  );
}

RoutePlan planOf(EngineRoute r, {List<Poi> pois = const []}) => RoutePlan(
      points: r.points,
      distanceM: r.distanceM,
      durationSec: r.durationSec,
      steps: r.steps,
      pois: pois,
      title: 'Test',
    );

void main() {
  group('Routen zusammensetzen', () {
    test('Teilstueck behaelt passende Anweisungen und Zeitanteil', () {
      final r = lineRoute(20);
      final part = sliceRoute(r, 5000, 15000);
      expect(pathLength(part.points), closeTo(10000, 1));
      expect(part.durationSec, closeTo(r.durationSec / 2, 1));
      expect(part.steps.length, 1);
      final s = part.steps.single;
      expect(s.type, ManeuverType.left);
      // Die Anweisung zeigt weiterhin auf die Mitte der Route.
      expect(dist(part.points[s.pointIndex], r.points[r.points.length ~/ 2]),
          lessThan(1));
    });

    test('Ersetzen: Anfang und Ende bleiben, Umweg dazwischen', () {
      final r = lineRoute(20);
      final a = pointAlong(r.points, cumulativeDistances(r.points), 8000);
      final b = pointAlong(r.points, cumulativeDistances(r.points), 12000);
      final side = destinationPoint(a, 0, 2000);
      final detour = EngineRoute(
        points: [a, side, destinationPoint(b, 0, 2000), b],
        distanceM: 8000,
        durationSec: 600,
      );
      final out = replaceSection(r, 8000, 12000, detour);
      expect(dist(out.points.first, r.points.first), lessThan(1));
      expect(dist(out.points.last, r.points.last), lessThan(1));
      expect(pathLength(out.points), closeTo(16000 + 8000, 10));
      // Anweisungen aus den behaltenen Stuecken: Start und Ziel.
      expect(out.steps.map((s) => s.type),
          containsAll([ManeuverType.start, ManeuverType.destination]));
      for (final s in out.steps) {
        expect(s.pointIndex, lessThan(out.points.length));
      }
    });

    test('Rueckfuehrung trifft die Route VOR dem Fahrer', () {
      final r = lineRoute(30);
      final cum = cumulativeDistances(r.points);
      // Fahrer 800 m neben der Route bei km 10, zuletzt auf ihr bei km 9.
      final here =
          destinationPoint(pointAlong(r.points, cum, 10000), 0, 800);
      final t = RoutePatcher.rejoinTarget(r.points, cum, here, 9000);
      expect(t, greaterThan(10000));
      expect(t, lessThan(12500));
    });

    test('Umfahrung schickt die gemiedenen Punkte an die Engine', () async {
      final engine = FakeEngine();
      final r = lineRoute(20);
      final avoid = [destinationPoint(home, 90, 10000)];
      final res = await RoutePatcher(engine, const RoutingPrefs())
          .avoidSection(r, fromM: 6000, toM: 14000, avoid: avoid);
      expect(engine.prefsSeen.single.avoid, avoid);
      expect(res.route.points.length, greaterThan(10));
    });
  });

  group('Verkehrslage', () {
    Map<String, dynamic> incident(String id, int icon, List<RoutePoint> pts,
            {int delay = 0, int mag = 0}) =>
        {
          'type': 'Feature',
          'geometry': {
            'type': pts.length == 1 ? 'Point' : 'LineString',
            'coordinates': pts.length == 1
                ? [pts.first.lon, pts.first.lat]
                : [
                    for (final p in pts) [p.lon, p.lat]
                  ],
          },
          'properties': {
            'id': id,
            'iconCategory': icon,
            'magnitudeOfDelay': mag,
            'delay': delay,
            'events': [
              {'description': 'Stau'}
            ],
            'roadNumbers': ['B54'],
          },
        };

    test('TomTom-Antwort wird gelesen', () {
      final list = TrafficService.parse({
        'incidents': [
          incident('a', 6, [home, destinationPoint(home, 90, 500)],
              delay: 600, mag: 3),
          incident('b', 8, [home]),
        ]
      });
      expect(list.length, 2);
      expect(list[0].category, TrafficCategory.jam);
      expect(list[0].delaySec, 600);
      expect(list[0].road, 'B54');
      expect(list[0].isSevere, isTrue);
      expect(list[1].isClosure, isTrue);
    });

    test('nur Meldungen AUF der Route und in Fahrtrichtung', () {
      final r = lineRoute(20);
      final cum = cumulativeDistances(r.points);
      RoutePoint at(double m, {double side = 0}) =>
          destinationPoint(pointAlong(r.points, cum, m), 0, side);
      final raw = TrafficService.parse({
        'incidents': [
          incident('on', 6, [at(5000), at(5500), at(6000)], delay: 400),
          incident('parallel', 6, [at(5000, side: 400), at(6000, side: 400)]),
          incident('wrongway', 6, [at(9000), at(8500), at(8000)]),
          incident('closed', 8, [at(12000)]),
        ]
      });
      final m = TrafficService.matchToRoute(raw, r.points, cum);
      expect(m.map((i) => i.id), ['on', 'closed']);
      expect(m.first.alongM, closeTo(5000, 5));
      expect(m.first.endAlongM, closeTo(6000, 5));
    });

    test('Rechtecke entlang der Route bleiben unter der Flaechengrenze', () {
      final pts = straight(home, 45, 400000, step: 1000);
      final boxes = TrafficService.routeBoxes(
          pts, cumulativeDistances(pts), 0, 400000);
      expect(boxes.length, 7);
      for (final b in boxes) {
        final hKm = (b.$3 - b.$1) * 111;
        final wKm = (b.$4 - b.$2) * 111 * 0.63;
        expect(hKm * wKm, lessThan(10000));
      }
    });

    test('Planen: Sperrung wird umfahren, Stau ohne Zeitgewinn nicht', () async {
      final r = lineRoute(40);
      final cum = cumulativeDistances(r.points);
      RoutePoint at(double m) => pointAlong(r.points, cum, m);
      final client = MockClient((req) async => http.Response(
          jsonEncode({
            'incidents': [
              incident('closed', 8, [at(10000), at(10300)]),
              incident('jam', 6, [at(30000), at(30500)], delay: 30, mag: 1),
            ]
          }),
          200));
      final engine = FakeEngine();
      final plan = await TrafficPlanCheck.apply(
        planOf(r),
        TrafficService('KEY', client: client),
        RoutePatcher(engine, const RoutingPrefs()),
      );
      expect(engine.calls, 1);
      expect(engine.prefsSeen.single.avoid, isNotEmpty);
      expect(plan.notes.where((n) => n.contains('Sperrung')), isNotEmpty);
      expect(plan.traffic.map((i) => i.id), ['jam']);
    });
  });

  group('Navigation', () {
    test('Abbiegehinweis: Vorwarnung, Ansage, dann weiter', () {
      final said = <String>[];
      final r = lineRoute(10);
      final nav = NavigationSession(
        plan: planOf(r),
        engine: FakeEngine(),
        prefs: const RoutingPrefs(),
        speak: said.add,
      );
      final cum = cumulativeDistances(r.points);
      void at(double m) {
        final p = pointAlong(r.points, cum, m);
        nav.update(p.lat, p.lon, heading: 90, speedMs: 15);
      }

      at(100);
      expect(nav.nextStep!.type, ManeuverType.left);
      expect(nav.distanceToNext, closeTo(4900, 20));
      at(4700); // 300 m vorher: Vorwarnung
      expect(said.last, startsWith('In 300 Metern'));
      at(4930); // 70 m vorher: Ansage
      expect(said.last, 'Links');
      at(5100);
      expect(nav.nextStep!.type, ManeuverType.destination);
      at(9990);
      expect(nav.arrived, isTrue);
    });

    test('Autobahn: Ausfahrt wird gestaffelt angesagt (3 km, 1 km, 400 m)',
        () {
      final said = <String>[];
      final pts = straight(home, 90, 20000, step: 100);
      final exit = RouteStep(
          text: 'Ausfahrt 23 nehmen',
          alert: 'Ausfahrt 23',
          verbal: 'Nehmen Sie die Ausfahrt 23.',
          distanceM: 0,
          pointIndex: 150,
          type: ManeuverType.exitRight);
      final nav = NavigationSession(
        plan: RoutePlan(points: pts, distanceM: 20000, steps: [exit]),
        engine: FakeEngine(),
        prefs: const RoutingPrefs(),
        speak: said.add,
      );
      final cum = cumulativeDistances(pts);
      for (var m = 5000.0; m < 15100; m += 30) {
        final p = pointAlong(pts, cum, m);
        nav.update(p.lat, p.lon, speedMs: 33); // ~120 km/h
      }
      expect(said, [
        'In 3 Kilometern: Ausfahrt 23',
        'In einem Kilometer: Ausfahrt 23',
        'In 400 Metern: Ausfahrt 23',
        'Nehmen Sie die Ausfahrt 23.',
      ]);
    });

    test('Stadt: nur kurze Vorwarnung', () {
      expect(NavigationSession.announceStages(ManeuverType.right, 10).first,
          250);
      expect(NavigationSession.announceStages(ManeuverType.exitRight, 30).first,
          3000);
    });

    test('verfahren: nach einigen Sekunden zurueck auf die Tour', () async {
      final engine = FakeEngine();
      final r = lineRoute(30);
      final nav = NavigationSession(
        plan: planOf(r),
        engine: engine,
        prefs: const RoutingPrefs(),
      );
      final cum = cumulativeDistances(r.points);
      final p = pointAlong(r.points, cum, 5000);
      nav.update(p.lat, p.lon, speedMs: 15);
      final off = destinationPoint(pointAlong(r.points, cum, 5500), 0, 400);
      nav.update(off.lat, off.lon, speedMs: 15);
      expect(engine.calls, 0); // nicht sofort
      // Zeit vergehen lassen: Beginn des "abseits" zurueckdatieren.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      nav.debugOffSince = DateTime.now().subtract(const Duration(seconds: 7));
      nav.update(off.lat, off.lon, speedMs: 15);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(engine.calls, 1);
      // Neue Route beginnt beim Fahrer und endet am alten Ziel.
      expect(dist(nav.plan.points.first, off), lessThan(1));
      expect(dist(nav.plan.points.last, r.points.last), lessThan(1));
      expect(nav.remainingM, lessThan(27000));
    });

    test('Funkloch: Route bleibt, Ansage nur einmal, seltener versuchen',
        () async {
      final engine = FakeEngine(failEvery: 1);
      final said = <String>[];
      final r = lineRoute(30);
      final nav = NavigationSession(
        plan: planOf(r),
        engine: engine,
        prefs: const RoutingPrefs(),
        speak: said.add,
      );
      final cum = cumulativeDistances(r.points);
      final p = pointAlong(r.points, cum, 5000);
      nav.update(p.lat, p.lon, speedMs: 15);
      said.clear();
      final off = destinationPoint(pointAlong(r.points, cum, 5500), 0, 400);
      for (var i = 0; i < 2; i++) {
        nav.debugOffSince = DateTime.now().subtract(const Duration(seconds: 7));
        nav.debugNoRerouteUntil = DateTime.fromMillisecondsSinceEpoch(0);
        nav.update(off.lat, off.lon, speedMs: 15);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.calls, 2);
      expect(nav.rerouteFails, 2);
      // Die geplante Route ist unveraendert.
      expect(nav.plan.points.length, r.points.length);
      expect(said.where((t) => t.contains('neu berechnet')).length, 1);
      expect(said.where((t) => t.contains('nicht möglich')).length, 1);
      // Zurueck auf der Route: Zaehler zurueckgesetzt.
      final back = pointAlong(r.points, cum, 6000);
      nav.update(back.lat, back.lon, speedMs: 15);
      expect(nav.rerouteFails, 0);
    });

    test('Stopp auslassen', () async {
      final engine = FakeEngine();
      final r = lineRoute(30);
      final cum = cumulativeDistances(r.points);
      final sp = pointAlong(r.points, cum, 15000);
      final stop = Poi(
          id: 's', kind: PoiKind.fuel, lat: sp.lat, lon: sp.lon,
          name: 'Tanke', source: 'stop');
      final nav = NavigationSession(
        plan: planOf(r, pois: [stop]),
        engine: engine,
        prefs: const RoutingPrefs(),
      );
      final p = pointAlong(r.points, cum, 5000);
      nav.update(p.lat, p.lon, speedMs: 15);
      expect(nav.nextStop!.poi.id, 's');
      expect(await nav.skipNextStop(), isTrue);
      expect(nav.nextStop, isNull);
    });
  });

  group('Andere Navi-Apps', () {
    test('Google Maps: hoechstens 9 Zwischenpunkte, Stopps immer dabei', () {
      final r = lineRoute(150);
      final cum = cumulativeDistances(r.points);
      final pois = [
        for (final km in [30.0, 90.0])
          () {
            final p = pointAlong(r.points, cum, km * 1000);
            return Poi(
                id: 'p$km', kind: PoiKind.fuel, lat: p.lat, lon: p.lon,
                source: 'stop');
          }(),
      ];
      final links = ExternalNav.googleMaps(planOf(r, pois: pois));
      expect(links.length, 1);
      final wp = links.single.uri.queryParameters['waypoints']!.split('|');
      expect(wp.length, lessThanOrEqualTo(9));
      for (final p in pois) {
        expect(wp, contains(
            '${p.lat.toStringAsFixed(6)},${p.lon.toStringAsFixed(6)}'));
      }
      expect(links.single.uri.queryParameters.containsKey('origin'), isFalse);
    });

    test('lange Tour: mehrere Abschnitte, lueckenlos', () {
      final r = lineRoute(700);
      final links = ExternalNav.googleMaps(planOf(r));
      expect(links.length, 4);
      for (var i = 1; i < links.length; i++) {
        expect(links[i].uri.queryParameters['origin'],
            links[i - 1].uri.queryParameters['destination']);
      }
    });

    test('Waze und geo: naechster Stopp als Ziel', () {
      final r = lineRoute(50);
      final cum = cumulativeDistances(r.points);
      final p = pointAlong(r.points, cum, 20000);
      final plan = planOf(r, pois: [
        Poi(id: 'x', kind: PoiKind.food, lat: p.lat, lon: p.lon,
            name: 'Café (Alt)', source: 'stop'),
      ]);
      final (target, name) = ExternalNav.nextTarget(plan);
      expect(dist(target, p), lessThan(1));
      expect(ExternalNav.waze(target).queryParameters['navigate'], 'yes');
      expect(ExternalNav.geo(target, name).toString(), startsWith('geo:'));
      final (after, _) = ExternalNav.nextTarget(plan, fromM: 25000);
      expect(dist(after, r.points.last), lessThan(1));
    });
  });
}

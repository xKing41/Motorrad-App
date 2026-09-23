import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/route_planner.dart';
import 'package:schraeglage/services/routing_engine.dart';

import 'helpers.dart';

void main() {
  const home = RoutePoint(51.305, 7.355); // Raum Gevelsberg/Ennepetal

  group('Rundtour-Form', () {
    test('Start liegt AUF der Schleife, nicht in der Mitte', () {
      final shape = LoopShape(
        bearing: 90,
        clockwise: true,
        angleJitter: const [0, 0, 0],
        radiusJitter: const [1, 1, 1],
      );
      final pts = shape.points(home, 10000);
      expect(pts.length, 3);
      // Mittelpunkt liegt 10 km oestlich; alle Hilfspunkte 10 km davon.
      final center = destinationPoint(home, 90, 10000);
      for (final p in pts) {
        expect(dist(center, p), closeTo(10000, 20));
      }
      // Gegenueber vom Start liegt ein Punkt 20 km entfernt.
      final far = pts.map((p) => dist(home, p)).reduce(math.max);
      expect(far, closeTo(20000, 50));
      // Viereck im Kreis: Umfang 4 * Wurzel(2) * r.
      expect(shape.perimeterFactor(home), closeTo(4 * math.sqrt2, 0.05));
    });

    test('Via-Ort in Reichweite ersetzt den naechsten Hilfspunkt', () {
      final shape = LoopShape(
        bearing: 0,
        clockwise: true,
        angleJitter: const [0, 0, 0],
        radiusJitter: const [1, 1, 1],
      );
      final via = destinationPoint(home, 5, 18000);
      final pts = shape.points(home, 10000, via: via);
      expect(pts.any((p) => identical(p, via)), isTrue);
    });
  });

  group('TourPlanner Rundtour', () {
    test('liefert Varianten, Start = Ziel, Laenge nachgeregelt', () async {
      final engine = FakeEngine(factor: 1.0);
      final planner = TourPlanner(engine, random: math.Random(7));
      final req = RouteRequest(
        startLat: home.lat,
        startLon: home.lon,
        distanceKm: 120,
        curviness: Curviness.curvy,
      );
      final messages = <String>[];
      final plan = await planner.plan(req, onProgress: messages.add);

      expect(plan.points.length, greaterThan(10));
      expect(dist(plan.points.first, home), lessThan(1));
      expect(dist(plan.points.last, home), lessThan(1));
      // Die Fake-Engine faehrt Luftlinie - der Planer schaetzt aber
      // Strassenumwege ein und muss deshalb nachregeln.
      expect(plan.distanceKm, closeTo(120, 120 * 0.15));
      expect(plan.stats, isNotNull);
      expect(plan.alternatives, isNotEmpty);
      expect(plan.alternatives.length, lessThanOrEqualTo(2));
      expect(plan.engineLabel, 'Test');
      expect(messages.any((m) => m.contains('Länge wird angepasst')), isTrue);
      // Hilfspunkte sind "shape", Start/Ziel "endpoint".
      final first = engine.requests.first;
      expect(first.first.kind, WaypointKind.endpoint);
      expect(first.last.kind, WaypointKind.endpoint);
      expect(first.skip(1).take(first.length - 2).every((w) => w.kind == WaypointKind.shape),
          isTrue);
    });

    test('Richtung Norden: die Tour liegt noerdlich vom Start', () async {
      final planner = TourPlanner(FakeEngine(), random: math.Random(3));
      final plan = await planner.plan(RouteRequest(
        startLat: home.lat,
        startLon: home.lon,
        distanceKm: 80,
        direction: TourDirection.n,
      ));
      final northMost = plan.points.map((p) => p.lat).reduce(math.max);
      final southMost = plan.points.map((p) => p.lat).reduce(math.min);
      expect(northMost - home.lat, greaterThan((home.lat - southMost) * 3));
    });

    test('einzelne Fehlschlaege der Engine werden verkraftet', () async {
      final planner = TourPlanner(FakeEngine(failEvery: 2), random: math.Random(1));
      final plan = await planner.plan(RouteRequest(
        startLat: home.lat,
        startLon: home.lon,
        distanceKm: 60,
      ));
      expect(plan.isEmpty, isFalse);
    });

    test('Wegpunkt-Limit der Engine wird eingehalten', () async {
      final engine = FakeEngine(maxWaypoints: 5);
      final planner = TourPlanner(engine, random: math.Random(2));
      await planner.plan(RouteRequest(
        startLat: home.lat,
        startLon: home.lon,
        distanceKm: 400,
      ));
      expect(engine.requests.every((r) => r.length <= 5), isTrue);
    });

    test('ohne jede Route gibt es eine verstaendliche Fehlermeldung', () async {
      final planner = TourPlanner(FakeEngine(failEvery: 1));
      expect(
        () => planner.plan(RouteRequest(
            startLat: home.lat, startLon: home.lon, distanceKm: 50)),
        throwsA(isA<RouteException>()),
      );
    });
  });

  group('TourPlanner A nach B', () {
    test('ohne Ziel: klare Meldung', () async {
      final planner = TourPlanner(FakeEngine());
      expect(
        () => planner.plan(RouteRequest(
            startLat: home.lat, startLon: home.lon, roundTrip: false)),
        throwsA(isA<RouteException>()),
      );
    });

    test('kurvig: bietet Umwege an, Ziel wird erreicht', () async {
      final engine = FakeEngine();
      final dest = destinationPoint(home, 60, 50000);
      final plan = await TourPlanner(engine).plan(RouteRequest(
        startLat: home.lat,
        startLon: home.lon,
        endLat: dest.lat,
        endLon: dest.lon,
        roundTrip: false,
        curviness: Curviness.curvy,
        destinationName: 'Testdorf',
      ));
      expect(dist(plan.points.last, dest), lessThan(1));
      expect(plan.title, 'Tour nach Testdorf');
      // Direkt + zwei Umwege.
      expect(engine.calls, 3);
    });
  });

  group('Bewertung', () {
    test('kurvige Strecke schlaegt gerade bei Wunsch "kurvig"', () {
      final straightRoute = straight(home, 0, 30000, step: 100);
      final twisty = wiggly(home, 0, 30000, amplitude: 100, wavelength: 600);
      final a = RouteScoring.evaluate(straightRoute,
          curviness: Curviness.curvy, lengthError: 0, roundTrip: false);
      final b = RouteScoring.evaluate(twisty,
          curviness: Curviness.curvy, lengthError: 0, roundTrip: false);
      expect(b.score, greaterThan(a.score + 10));
      // Bei "direkt" spielt die Kurvigkeit keine Rolle.
      final c = RouteScoring.evaluate(straightRoute,
          curviness: Curviness.direct, lengthError: 0, roundTrip: false);
      final d = RouteScoring.evaluate(twisty,
          curviness: Curviness.direct, lengthError: 0, roundTrip: false);
      expect((c.score - d.score).abs(), lessThan(1));
    });

    test('doppelt gefahrene Strecke kostet deutlich', () {
      final loop = circle(home, 5000, n: 300);
      final out = straight(home, 90, 6000, step: 100);
      final outAndBack = [...out, ...out.reversed.skip(1)];
      final a = RouteScoring.evaluate(loop,
          curviness: Curviness.balanced, lengthError: 0);
      final b = RouteScoring.evaluate(outAndBack,
          curviness: Curviness.balanced, lengthError: 0);
      expect(b.overlap, greaterThan(0.7));
      expect(a.score, greaterThan(b.score + 80));
    });

    test('Laengenabweichung bis 8 % ist frei, darueber teuer', () {
      final loop = circle(home, 5000, n: 300);
      final ok = RouteScoring.evaluate(loop,
          curviness: Curviness.direct, lengthError: 0.07);
      final bad = RouteScoring.evaluate(loop,
          curviness: Curviness.direct, lengthError: 0.4);
      expect(ok.score, greaterThan(bad.score + 30));
    });

    test('eigene Strecken zaehlen nur mit Wunsch', () {
      final loop = circle(home, 3000, n: 200);
      final heat = <String, double>{
        for (final p in resample(loop, 20))
          '${p.lat.toStringAsFixed(3)},${p.lon.toStringAsFixed(3)}': 30,
      };
      final without = RouteScoring.evaluate(loop,
          curviness: Curviness.curvy, lengthError: 0, heatmap: heat);
      final with_ = RouteScoring.evaluate(loop,
          curviness: Curviness.curvy,
          lengthError: 0,
          heatmap: heat,
          preferKnown: true);
      expect(without.knownShare, greaterThan(0.9));
      expect(with_.score, greaterThan(without.score + 20));
    });

    test('Aehnlichkeit: gleich = 1, verschieden = klein', () {
      final a = circle(home, 5000, n: 200);
      final b = circle(destinationPoint(home, 180, 12000), 5000, n: 200);
      expect(RouteScoring.similarity(a, a), closeTo(1, 1e-9));
      expect(RouteScoring.similarity(a, b), lessThan(0.1));
    });
  });

  group('Zwischenstopps', () {
    final route = straight(home, 90, 100000, step: 200);
    Poi poi(String id, PoiKind k, double alongKm, double sideM,
            {String? name, String? detail}) {
      final base = destinationPoint(home, 90, alongKm * 1000);
      final p = destinationPoint(base, 0, sideM);
      return Poi(id: id, kind: k, lat: p.lat, lon: p.lon, name: name, detail: detail);
    }

    StopCandidate cand(Poi p) {
      final cum = cumulativeDistances(route);
      final hit = projectOnPolyline(RoutePoint(p.lat, p.lon), route, cum)!;
      return StopCandidate(p, hit.alongM, hit.distanceM);
    }

    test('nimmt die Tankstelle nahe "nach 60 km", lieber frueher als spaeter', () {
      final found = [
        poi('a', PoiKind.fuel, 40, 100, name: 'A'),
        poi('b', PoiKind.fuel, 57, 300, name: 'B'),
        poi('c', PoiKind.fuel, 63, 300, name: 'C'),
      ];
      final slots = TourPlanner.planSlots(
          [StopWish(kind: PoiKind.fuel, afterKm: 60)], 100000,
          fuelEveryKm: 500);
      final chosen =
          TourPlanner.chooseStops(slots, found.map(cand).toList());
      expect(chosen.length, 1);
      expect(chosen.first.$1.id, 'b');
      expect(chosen.first.$1.source, 'stop');
      expect(chosen.first.$2, closeTo(57000, 200));
    });

    test('Aussichtspunkt schlaegt Gipfel im Wald', () {
      final found = [
        poi('peak', PoiKind.viewpoint, 50, 100, name: 'Kahler Asten', detail: 'Gipfel'),
        poi('view', PoiKind.viewpoint, 51, 200,
            name: 'Aussicht', detail: 'Aussichtspunkt'),
      ];
      final slots = TourPlanner.planSlots(
          [StopWish(kind: PoiKind.viewpoint)], 100000);
      final chosen =
          TourPlanner.chooseStops(slots, found.map(cand).toList());
      expect(chosen.single.$1.id, 'view');
    });

    test('3100 km mit Tankwunsch: Tankstopp spaetestens alle 150 km', () {
      final slots = TourPlanner.planSlots(
          [StopWish(kind: PoiKind.fuel, repeat: true)], 3100000,
          fuelEveryKm: 150);
      final fuel = slots.where((s) => s.kind == PoiKind.fuel).toList();
      expect(fuel.length, 20);
      var last = 0.0;
      for (final s in [...fuel.map((s) => s.targetM), 3100000.0]) {
        expect(s - last, lessThanOrEqualTo(150000 + 1));
        last = s;
      }
    });

    test('auch EIN Tankstopp der KI wird auf lange Strecke aufgefuellt', () {
      final slots = TourPlanner.planSlots(
          [StopWish(kind: PoiKind.fuel, afterKm: 100, reason: 'KI')], 800000,
          fuelEveryKm: 200);
      final fuel = slots.where((s) => s.kind == PoiKind.fuel).toList();
      expect(fuel.length, 4); // 100, 300, 500, 700
      expect(fuel.first.targetM, 100000);
    });

    test('Pausen wechseln zwischen Rastplatz und Einkehr', () {
      final slots = TourPlanner.planSlots([
        StopWish(kind: PoiKind.rest, repeat: true),
        StopWish(kind: PoiKind.food, repeat: true),
      ], 450000, breakEveryKm: 100);
      final kinds = slots.map((s) => s.kind).toList();
      expect(kinds, [
        PoiKind.rest,
        PoiKind.food,
        PoiKind.rest,
        PoiKind.food,
      ]);
    });

    test('kurze Tour: je Art genau ein Stopp', () {
      final slots = TourPlanner.planSlots([
        StopWish(kind: PoiKind.fuel, repeat: true),
        StopWish(kind: PoiKind.viewpoint, repeat: true),
      ], 60000);
      expect(slots.where((s) => s.kind == PoiKind.fuel).length, 1);
      expect(slots.where((s) => s.kind == PoiKind.viewpoint).length, 1);
    });

    test('Tankstopps halten die Reichweite ein, auch wenn die Stelle '
        'selbst nichts bietet', () {
      final long = straight(home, 90, 600000, step: 500);
      final cum = cumulativeDistances(long);
      StopCandidate at(String id, double km) {
        final p = pointAlong(long, cum, km * 1000);
        return StopCandidate(
            Poi(id: id, kind: PoiKind.fuel, lat: p.lat, lon: p.lon, name: id),
            km * 1000,
            50);
      }

      final cands = [at('t1', 120), at('t2', 160), at('t3', 250), at('t4', 290),
        at('t5', 420), at('t6', 455), at('t7', 560)];
      final slots = TourPlanner.planSlots(
          [StopWish(kind: PoiKind.fuel, repeat: true)], 600000,
          fuelEveryKm: 150);
      final chosen = TourPlanner.chooseStops(slots, cands,
          fuelEveryM: 150000, totalM: 600000);
      expect(chosen.map((c) => c.$1.id), ['t1', 't3', 't4', 't5', 't7']);
      var last = 0.0;
      for (final c in chosen) {
        expect(c.$2 - last, lessThanOrEqualTo(150000));
        last = c.$2;
      }
      expect(TourPlanner.fuelGaps(chosen, 600000,
          fuelEveryM: 150000, wanted: true), 0);
    });

    test('Suchabschnitte werden zusammengefasst', () {
      final slots = TourPlanner.planSlots([
        StopWish(kind: PoiKind.fuel, repeat: true),
        StopWish(kind: PoiKind.rest, repeat: true),
      ], 1000000, fuelEveryKm: 150, breakEveryKm: 100);
      final secs = TourPlanner.mergeSections(slots, 1000000);
      expect(secs.length, lessThan(slots.length));
      for (final s in secs) {
        expect(s.hiM - s.loM, lessThanOrEqualTo(120000 + 1));
      }
    });

    test('Wegpunkte werden in Stuecke fuer den Server geteilt', () {
      final long = straight(home, 90, 1000000, step: 1000);
      final cum = cumulativeDistances(long);
      final wps = [
        (const Waypoint(home, WaypointKind.endpoint), 0.0),
        (Waypoint(long.last, WaypointKind.endpoint), cum.last),
      ];
      final chunks = TourPlanner.chunkWaypoints(wps, long, cum);
      expect(chunks.length, greaterThanOrEqualTo(4));
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].last.$2 - chunks[i].first.$2,
            lessThanOrEqualTo(250000 + 1));
        if (i > 0) expect(chunks[i].first.$2, chunks[i - 1].last.$2);
      }
      expect(chunks.first.first.$2, 0);
      expect(chunks.last.last.$2, cum.last);
    });

    test('Stopps werden in der richtigen Reihenfolge eingefuegt', () {
      final wps = [
        const Waypoint(home, WaypointKind.endpoint),
        Waypoint(destinationPoint(home, 90, 50000), WaypointKind.shape),
        Waypoint(destinationPoint(home, 90, 100000), WaypointKind.endpoint),
      ];
      final s1 = poi('s1', PoiKind.fuel, 30, 50);
      final s2 = poi('s2', PoiKind.food, 70, 50);
      final out = TourPlanner.insertStops(wps, [(s1, 30000.0), (s2, 70000.0)], route);
      expect(out.map((w) => w.kind).toList(), [
        WaypointKind.endpoint,
        WaypointKind.stop,
        WaypointKind.shape,
        WaypointKind.stop,
        WaypointKind.endpoint,
      ]);
    });
  });

  group('Lange Strecken', () {
    test('Etappenpunkte hoechstens 300 km auseinander', () {
      const ankara = RoutePoint(39.93, 32.86);
      final pts = TourPlanner.legPoints(home, ankara);
      expect(pts.first, home);
      expect(pts.last, ankara);
      for (var i = 1; i < pts.length; i++) {
        expect(dist(pts[i - 1], pts[i]), lessThanOrEqualTo(300001));
      }
    });

    test('A nach B ueber 350 km wird in Etappen gerechnet', () async {
      final engine = FakeEngine();
      final dest = destinationPoint(home, 120, 850000);
      final plan = await TourPlanner(engine).plan(RouteRequest(
        startLat: home.lat,
        startLon: home.lon,
        endLat: dest.lat,
        endLon: dest.lon,
        roundTrip: false,
      ));
      expect(engine.calls, 3);
      expect(engine.requests.every((r) => r.length == 2), isTrue);
      expect(dist(plan.points.first, home), lessThan(1));
      expect(dist(plan.points.last, dest), lessThan(1));
      expect(plan.distanceKm, closeTo(850, 20));
    });

    test('Teilstueck einer Route', () {
      final line = straight(home, 90, 100000, step: 1000);
      final cum = cumulativeDistances(line);
      final part = subPath(line, cum, 40000, 60000);
      expect(pathLength(part), closeTo(20000, 50));
      final clipped = subPath(line, cum, -5000, 10000);
      expect(pathLength(clipped), closeTo(10000, 50));
    });

    test('850 km mit Tankwunsch: viele Tankstopps, Route in Stuecken', () async {
      final engine = FakeEngine();
      final dest = destinationPoint(home, 120, 850000);
      // Alle 25 km eine Tankstelle, 300 m neben der Luftlinie.
      final stations = <Poi>[
        for (var km = 10; km < 850; km += 25)
          () {
            final p = destinationPoint(
                destinationPoint(home, 120, km * 1000.0), 30, 300);
            return Poi(
                id: 'fuel$km', kind: PoiKind.fuel, lat: p.lat, lon: p.lon,
                name: 'T$km');
          }(),
      ];
      var searches = 0;
      Future<List<Poi>?> search(
          List<RoutePoint> route, List<PoiKind> kinds, double corridor) async {
        searches++;
        final cum = cumulativeDistances(route);
        return [
          for (final s in stations)
            if (kinds.contains(s.kind) &&
                projectOnPolyline(RoutePoint(s.lat, s.lon), route, cum)!
                        .distanceM <
                    corridor)
              s,
        ];
      }

      final plan = await TourPlanner(engine, poiSearch: search).plan(
          RouteRequest(
            startLat: home.lat,
            startLon: home.lon,
            endLat: dest.lat,
            endLon: dest.lon,
            roundTrip: false,
            fuelEveryKm: 150,
            stops: [StopWish(kind: PoiKind.fuel, repeat: true)],
          ));
      final fuel = plan.pois.where((p) => p.kind == PoiKind.fuel).toList();
      expect(fuel.length, greaterThanOrEqualTo(5));
      expect(searches, greaterThanOrEqualTo(3));
      expect(plan.notes.where((n) => n.contains('nur markiert')), isEmpty);
      expect(plan.notes.where((n) => n.contains('Achtung')), isEmpty);
      // Keine Anfrage ueber zu lange Strecken.
      for (final r in engine.requests) {
        var len = 0.0;
        for (var i = 1; i < r.length; i++) {
          len += dist(r[i - 1].point, r[i].point);
        }
        expect(len, lessThan(320000));
      }
      // Die Route fuehrt wirklich an den Tankstellen vorbei.
      final cum = cumulativeDistances(plan.points);
      for (final f in fuel) {
        final hit =
            projectOnPolyline(RoutePoint(f.lat, f.lon), plan.points, cum)!;
        expect(hit.distanceM, lessThan(5));
      }
    });
  });
}

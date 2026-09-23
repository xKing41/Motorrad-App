import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/tour_store.dart';

import 'helpers.dart';

RoutePlan samplePlan() {
  final pts = straight(const RoutePoint(48.1234567, 9.7654321), 45, 30000,
      step: 37);
  return RoutePlan(
    points: pts,
    distanceM: 30123,
    durationSec: 2400,
    steps: [
      RouteStep(text: 'Los', distanceM: 0, pointIndex: 0, type: ManeuverType.start),
      RouteStep(
          text: 'Rechts',
          distanceM: 500,
          pointIndex: 100,
          type: ManeuverType.right,
          verbal: 'Biegen Sie rechts ab.',
          alert: 'Rechts abbiegen.'),
    ],
    pois: [
      Poi(id: 'f1', kind: PoiKind.fuel, lat: 48.2, lon: 9.8, name: 'Aral',
          source: 'stop'),
    ],
    title: 'Albtour',
    stats: const RouteStats(
        curvIndex: 0.8,
        curvLabel: 'kurvig',
        bendsPerKm: 3.2,
        overlapShare: 0.05,
        knownShare: 0,
        score: 1.4),
    roundTrip: true,
    request: RouteRequest(
      startLat: 48.1,
      startLon: 9.7,
      viaLat: 48.3,
      viaLon: 9.9,
      distanceKm: 120,
      curviness: Curviness.veryCurvy,
      avoidMotorways: false,
      avoidTolls: true,
      stops: [StopWish(kind: PoiKind.fuel, repeat: true)],
      fuelEveryKm: 180,
      breakEveryKm: 90,
    ),
  );
}

void main() {
  test('Route hin und zurueck: Linie, Anweisungen, Stopps, Vorgaben', () {
    final p = samplePlan();
    final q = planFromJson(planToJson(p))!;
    expect(q.points.length, p.points.length);
    for (var i = 0; i < p.points.length; i += 50) {
      expect(dist(q.points[i], p.points[i]), lessThan(0.2));
    }
    expect(q.distanceM, p.distanceM);
    expect(q.durationSec, 2400);
    expect(q.steps[1].type, ManeuverType.right);
    expect(q.steps[1].verbal, 'Biegen Sie rechts ab.');
    expect(q.steps[1].pointIndex, 100);
    expect(q.pois.single.name, 'Aral');
    expect(q.pois.single.source, 'stop');
    expect(q.stats!.curvLabel, 'kurvig');
    expect(q.roundTrip, isTrue);
    final r = q.request!;
    expect(r.avoidMotorways, isFalse);
    expect(r.avoidTolls, isTrue);
    expect(r.curviness, Curviness.veryCurvy);
    expect(r.viaLat, 48.3);
    expect(r.stops.single.repeat, isTrue);
    expect(r.fuelEveryKm, 180);
    expect(r.breakEveryKm, 90);
  });

  test('kaputte Daten: null statt Absturz, falsche Indizes verworfen', () {
    expect(planFromJson(null), isNull);
    expect(planFromJson({'line': 42}), isNull);
    final j = planToJson(samplePlan());
    (j['steps'] as List).add({'t': 'x', 'i': 999999});
    expect(planFromJson(j)!.steps.length, 2);
  });

  group('Speicher', () {
    late Directory dir;
    late TourStore store;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('tours');
      store = TourStore(dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('speichern, auflisten, laden, umbenennen, loeschen', () async {
      final m = await store.save(samplePlan());
      expect(m.title, 'Albtour');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final m2 = await store.save(samplePlan(), title: '  ');
      expect(m2.title, 'Tour 30 km');
      var l = await store.list();
      expect(l.map((e) => e.id), [m2.id, m.id]); // neueste zuerst
      expect((await store.load(m.id))!.points.length,
          samplePlan().points.length);
      await store.rename(m.id, 'Schwäbische Alb');
      l = await store.list();
      expect(l.firstWhere((e) => e.id == m.id).title, 'Schwäbische Alb');
      await store.delete(m2.id);
      l = await store.list();
      expect(l.length, 1);
      expect(await store.load(m2.id), isNull);
    });

    test('zuletzt geplant: immer oben, wird ersetzt', () async {
      await store.save(samplePlan(), title: 'A');
      await store.saveLast(samplePlan());
      await store.saveLast(samplePlan());
      final l = await store.list();
      expect(l.length, 2);
      expect(l.first.isLast, isTrue);
    });

    test('Index kaputt: wird aus den Dateien neu aufgebaut', () async {
      final m = await store.save(samplePlan(), title: 'Rettung');
      File('${dir.path}/index.json').writeAsStringSync('{kaputt');
      final l = await store.list();
      expect(l.single.id, m.id);
      expect(l.single.title, 'Rettung');
    });
  });
}

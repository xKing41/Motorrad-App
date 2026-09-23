import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/ride.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/backup_service.dart';
import 'package:schraeglage/services/ride_store.dart';
import 'package:schraeglage/services/tour_store.dart';

import 'helpers.dart';

RideSummary ride(String id, int startMs) => RideSummary(
      id: id,
      start: DateTime.fromMillisecondsSinceEpoch(startMs),
      durationSec: 600,
      distanceM: 12000,
      maxLeanL: 30,
      maxLeanR: 32,
      maxSpeedMs: 25,
      maxBrakeG: 0.5,
      maxLatG: 0.6,
      pointCount: 3,
    );

final track = [
  TrackPoint(lat: 51, lon: 7, tMs: 0, speedMs: 10, lean: 0),
  TrackPoint(lat: 51.001, lon: 7, tMs: 700, speedMs: 12, lean: 5),
  TrackPoint(lat: 51.002, lon: 7, tMs: 1400, speedMs: 14, lean: -8),
];

RoutePlan plan(String title) {
  final pts = straight(const RoutePoint(48, 9), 90, 5000);
  return RoutePlan(points: pts, distanceM: 5000, title: title);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('backup'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('Sicherung hin und zurueck auf ein "neues Handy"', () async {
    final rides = RideStore.at(Directory('${tmp.path}/a/rides')..createSync(recursive: true));
    final tours = TourStore(Directory('${tmp.path}/a/tours'));
    await rides.saveRide(ride('r1', 1000), track);
    await rides.saveRide(ride('r2', 5000), track);
    await tours.save(plan('Alb'), title: 'Alb');
    await tours.saveLast(plan('zuletzt'));

    final file = File('${tmp.path}/s.json.gz');
    final out = await BackupService.export(file, rides, tours);
    expect(out.rides, 2);
    expect(out.tours, 1); // "zuletzt geplant" gehoert nicht dazu

    final rides2 = RideStore.at(Directory('${tmp.path}/b/rides')..createSync(recursive: true));
    final tours2 = TourStore(Directory('${tmp.path}/b/tours'));
    final res = await BackupService.import(file.openRead(), rides2, tours2);
    expect(res.rides, 2);
    expect(res.tours, 1);
    final l = await rides2.listRides();
    expect(l.map((r) => r.id), ['r2', 'r1']);
    final t = await rides2.loadTrack('r1');
    expect(t.length, 3);
    expect(t[2].lean, -8);
    final tl = await tours2.list();
    expect(tl.single.title, 'Alb');
    expect((await tours2.load(tl.single.id))!.points.length,
        plan('x').points.length);

    // Zweites Einspielen: nichts doppelt.
    final again = await BackupService.import(file.openRead(), rides2, tours2);
    expect(again.rides, 0);
    expect(again.skipped, 3);
    expect(again.text, '0 Fahrten, 0 Touren (3 schon vorhanden)');
  });

  test('fremde Datei wird abgelehnt', () async {
    final f = File('${tmp.path}/x.gz')
      ..writeAsBytesSync(gzip.encode('{"type":"meta","format":"anders"}\n'.codeUnits));
    final rides = RideStore.at(Directory('${tmp.path}/r')..createSync());
    final tours = TourStore(Directory('${tmp.path}/t'));
    expect(BackupService.import(f.openRead(), rides, tours),
        throwsA(isA<FormatException>()));
    final g = File('${tmp.path}/y.txt')..writeAsStringSync('hallo');
    expect(BackupService.import(g.openRead(), rides, tours), throwsA(anything));
  });
}

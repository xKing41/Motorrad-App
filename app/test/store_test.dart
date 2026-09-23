import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/ride.dart';
import 'package:schraeglage/services/ride_store.dart';

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
      pointCount: 2,
    );

final pts = [
  TrackPoint(lat: 51, lon: 7, tMs: 0, speedMs: 10, lean: 0),
  TrackPoint(lat: 51.001, lon: 7, tMs: 700, speedMs: 10, lean: 5),
];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('rides'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('kaputter Index: Fahrten werden aus den Dateien wiederhergestellt',
      () async {
    final store = RideStore.at(dir);
    await store.saveRide(ride('a', 1000), pts);
    await store.saveRide(ride('b', 2000), pts);
    File('${dir.path}/index.json').writeAsStringSync('[{"id": "a", "sta');
    final list = await store.listRides();
    expect(list.map((r) => r.id), ['b', 'a']);
    // Und danach ist der Index wieder heil.
    expect(File('${dir.path}/index.json').readAsStringSync(), contains('"b"'));
  });

  test('unterbrochene Fahrt wird beim naechsten Start gespeichert', () async {
    final store = RideStore.at(dir);
    await store.saveActive(ride('c', 3000), pts);
    final r = await store.recoverActive();
    expect(r?.title, 'Unterbrochene Fahrt');
    expect((await store.listRides()).single.id, 'c');
    expect(await store.loadTrack('c'), hasLength(2));
    // Nur einmal.
    expect(await store.recoverActive(), isNull);
  });

  test('regulaer beendet: nichts wiederherzustellen', () async {
    final store = RideStore.at(dir);
    await store.saveActive(ride('d', 4000), pts);
    await store.clearActive();
    expect(await store.recoverActive(), isNull);
  });
}

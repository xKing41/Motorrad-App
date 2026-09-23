import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/ride.dart';
import 'package:schraeglage/services/rider_profile.dart';

Corner corner(int dir, double lean, double apexKmh,
        {double entryKmh = 0, double? latG}) =>
    Corner(
      startIndex: 0,
      endIndex: 1,
      maxLean: lean,
      direction: dir,
      entrySpeedKmh: entryKmh == 0 ? apexKmh * 1.1 : entryKmh,
      minSpeedKmh: apexKmh,
      exitSpeedKmh: apexKmh,
      lat: 0,
      lon: 0,
      apexSpeedKmh: apexKmh,
      apexLatG: latG,
    );

RideSummary ride(int day) => RideSummary(
      id: 'r$day',
      start: DateTime(2026, 5, day),
      durationSec: 3600,
      distanceM: 50000,
      maxLeanL: 30,
      maxLeanR: 30,
      maxSpeedMs: 30,
      maxBrakeG: 0.5,
      maxLatG: 0.6,
      pointCount: 100,
    );

void main() {
  test('Seitenunterschied in derselben Kurvenart wird erkannt', () {
    // Mittlere Kurven (~ r 80-100 m): rechts 30°, links 22°.
    final cs = [
      for (var i = 0; i < 10; i++) corner(1, 30, 80, latG: 0.55),
      for (var i = 0; i < 10; i++) corner(-1, 22, 70, latG: 0.4),
    ];
    final p = RiderProfile.of([RideCorners(ride(1), cs)]);
    expect(p.corners, 20);
    expect(p.left!.avgLean, closeTo(22, 0.01));
    expect(p.right!.avgLean, closeTo(30, 0.01));
    expect(p.insights.first, startsWith('Mittlere Kurven: links legst du'));
    expect(p.insights.first, contains('8° weniger'));
    expect(p.insights.first, endsWith('durch die Linkskurven schauen.'));
  });

  test('Bremsen bis zum Scheitel in engen Kurven', () {
    final cs = [
      for (var i = 0; i < 10; i++)
        corner(i.isEven ? 1 : -1, 25, 30, entryKmh: 60, latG: 0.45),
    ];
    final p = RiderProfile.of([RideCorners(ride(1), cs)]);
    // r = (30/3,6)² / (0,45*9,81) = 15,7 m -> eng.
    expect(p.byClass[RadiusClass.tight]!.$1!.count, 5);
    expect(p.insights.any((s) => s.startsWith('In engen Kurven fällt dein Tempo')),
        isTrue);
  });

  test('Verlauf: steigende Schraeglage wird gelobt', () {
    final rides = [
      for (var d = 1; d <= 9; d++)
        RideCorners(ride(d), [
          for (var i = 0; i < 6; i++) corner(1, 15.0 + d, 60, latG: 0.4),
        ]),
    ];
    final p = RiderProfile.of(rides);
    expect(p.trend.length, 9);
    expect(p.trend.first.$2, 16);
    expect(p.insights.any((s) => s.contains('gestiegen')), isTrue);
  });

  test('zu wenig Daten: keine voreiligen Schluesse', () {
    final p = RiderProfile.of([
      RideCorners(ride(1), [corner(1, 35, 60), corner(-1, 15, 40)]),
    ]);
    expect(p.insights, isEmpty);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/ride.dart';
import 'package:schraeglage/services/ride_analysis.dart';

List<TrackPoint> track(List<(double speedMs, double lean)> pts) => [
      for (var i = 0; i < pts.length; i++)
        TrackPoint(
          lat: 51 + i * 0.0001,
          lon: 7,
          tMs: i * 700,
          speedMs: pts[i].$1,
          lean: pts[i].$2,
        ),
    ];

void main() {
  test('Seitenstaender im Stand ist keine Kurve', () {
    final t = track([
      for (var i = 0; i < 20; i++) (0.0, -15.0), // geparkt
      for (var i = 0; i < 10; i++) (15.0, 0.0),
    ]);
    expect(detectCorners(t), isEmpty);
    final a = RideAnalysis.of(t);
    expect(a.histogram.totalSeconds, closeTo(10 * 0.7, 1e-6));
  });

  test('echte Kurve wird erkannt, Radius aus Tempo am Scheitel', () {
    final t = track([
      for (var i = 0; i < 5; i++) (20.0, 0.0),
      (14.0, 20.0),
      (12.0, 30.0), // Scheitel: 12 m/s bei 30 Grad
      (8.0, 25.0), // langsamster Punkt, aber weniger Schraeglage
      (12.0, 15.0),
      for (var i = 0; i < 5; i++) (20.0, 0.0),
    ]);
    final c = detectCorners(t).single;
    expect(c.direction, 1);
    expect(c.maxLean, 30);
    expect(c.apexSpeedKmh, closeTo(12 * 3.6, 1e-9));
    // Alte Fahrt ohne Messwert: Radius aus der Schraeglage, mit
    // Reifenkorrektur (30 Grad Motorrad ~ 26 Grad effektiv) -> ~30 m.
    expect(RideAnalysis.radiusOf(c), inInclusiveRange(28.0, 32.0));
  });

  test('gemessene Querbeschleunigung hat Vorrang', () {
    final t = [
      for (var i = 0; i < 9; i++)
        TrackPoint(
          lat: 51 + i * 0.0001,
          lon: 7,
          tMs: i * 700,
          speedMs: 20,
          lean: i == 4 ? 35 : (i == 3 || i == 5 ? 20 : 0),
          latG: i == 4 ? 0.8 : 0.1,
        ),
    ];
    final c = detectCorners(t).single;
    // r = v^2 / a = 400 / (0,8 * 9,81) ~ 51 m
    expect(RideAnalysis.radiusOf(c), closeTo(51, 1));
  });
}

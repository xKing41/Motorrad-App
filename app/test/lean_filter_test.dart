import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/services/dynamics.dart';
import 'package:schraeglage/services/lean_filter.dart';

/// Simulierte Fahrt mit 50 Hz: Wechselkurven, Gyroskop mit Nullpunkt-
/// fehler und Rauschen, Referenz verrauscht wie die GPS-Rechnung.
({double rms, double bias, double lag}) simulate({
  required double gyroBias,
  required double refNoise,
  double seconds = 120,
}) {
  final rnd = math.Random(7);
  double gauss() =>
      math.sqrt(-2 * math.log(1 - rnd.nextDouble())) *
      math.cos(2 * math.pi * rnd.nextDouble());
  final kf = LeanKalman(qAngle: 0.12);
  const dt = 0.02;
  var sq = 0.0;
  var n = 0;
  double truth(double t) => 35 * math.sin(2 * math.pi * t / 12);
  for (var t = 0.0; t < seconds; t += dt) {
    final rate = (truth(t + dt) - truth(t)) / dt;
    kf.predict(rate + gyroBias + gauss() * 0.5, dt);
    kf.update(truth(t + dt) + gauss() * refNoise, refNoise * refNoise);
    if (t > seconds / 2) {
      final e = kf.angle - truth(t + dt);
      sq += e * e;
      n++;
    }
  }
  return (rms: math.sqrt(sq / n), bias: kf.bias, lag: 0);
}

void main() {
  test('Kalman lernt den Nullpunktfehler des Gyroskops', () {
    final r = simulate(gyroBias: 1.5, refNoise: 4);
    expect(r.bias, closeTo(1.5, 0.3));
    // Trotz 4 Grad Rauschen in der Referenz und 1,5 Grad/s Drift.
    expect(r.rms, lessThan(1.5));
  });

  test('ohne Drift: genauer als die Referenz selbst', () {
    final r = simulate(gyroBias: 0, refNoise: 4);
    expect(r.rms, lessThan(2.0));
  });

  test('Unsicherheit der GPS-Referenz faellt mit dem Tempo', () {
    expect(LeanKalman.rGps(8), greaterThan(LeanKalman.rGps(30)));
    expect(LeanKalman.rAccel(still: true), lessThan(LeanKalman.rAccel(still: false)));
  });

  test('Gyro-Nullpunkt wird im Stillstand gemessen, in Fahrt nicht', () {
    final b = GyroBiasTracker();
    const dt = 0.02;
    for (var i = 0; i < 200; i++) {
      b.feed(0.01, -0.02, 0.005, 1.0, dt, moving: false);
    }
    expect(b.hasBias, isTrue);
    expect(b.bx, closeTo(0.01, 1e-9));
    expect(b.by, closeTo(-0.02, 1e-9));
    final before = b.bx;
    for (var i = 0; i < 200; i++) {
      b.feed(0.03, 0.0, 0.0, 1.0, dt, moving: true);
    }
    expect(b.bx, before);
    // Bewegtes Handy (Stoss) im Stand: keine Messung.
    final c = GyroBiasTracker();
    for (var i = 0; i < 200; i++) {
      c.feed(0.01, 0, 0, i.isEven ? 1.3 : 0.8, dt, moving: false);
    }
    expect(c.hasBias, isFalse);
  });

  test('Motorrad-Profil: breitere Reifen -> groessere Korrektur', () {
    const schmal = BikeProfile(frontWidthMm: 100, rearWidthMm: 130);
    const breit = BikeProfile(frontWidthMm: 120, rearWidthMm: 200);
    expect(breit.bikeLeanDeg(40), greaterThan(schmal.bikeLeanDeg(40)));
    expect(BikeProfile.fromList(breit.toList()).rearWidthMm, 200);
  });
}

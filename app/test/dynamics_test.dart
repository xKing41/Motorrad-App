import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/services/dynamics.dart';

void main() {
  test('Querbeschleunigung aus Tempo und Drehrate, nicht aus der Lage', () {
    // Kreisfahrt: 20 m/s auf 50 m Radius -> a = v^2/r = 8 m/s^2 = 0,816 g.
    const v = 20.0, r = 50.0;
    const a = v * v / r / Dynamics.g;
    final phiEff = math.atan(a);
    // Das mitgeneigte Handy misst die Drehrate um die geneigte Hochachse.
    final yawMeasured = v / r * math.cos(phiEff);
    expect(Dynamics.lateralG(v, yawMeasured), closeTo(a, 1e-9));
    expect(Dynamics.effectiveLeanDeg(v, yawMeasured),
        closeTo(phiEff * 180 / math.pi, 1e-9));
  });

  test('im Stand gibt es keine Querbeschleunigung', () {
    expect(Dynamics.lateralG(0, 0.5), 0);
  });

  test('Reifenkorrektur: Motorrad liegt tiefer als die effektive Linie', () {
    expect(Dynamics.bikeLeanDeg(0), 0);
    final b40 = Dynamics.bikeLeanDeg(40);
    expect(b40, inInclusiveRange(45.0, 48.0));
    expect(Dynamics.bikeLeanDeg(-40), closeTo(-b40, 1e-9));
    // Hin und zurueck.
    for (final e in [5.0, 20.0, 35.0, 50.0]) {
      expect(Dynamics.effectiveFromBikeDeg(Dynamics.bikeLeanDeg(e)),
          closeTo(e, 1e-6));
    }
  });

  test('nicht linear: Querbeschleunigung waechst mit tan, nicht mit dem Winkel',
      () {
    final g20 = Dynamics.lateralGFromLean(20);
    final g40 = Dynamics.lateralGFromLean(40);
    expect(g40 / g20, greaterThan(2.2));
  });

  test('Radius', () {
    expect(Dynamics.radiusM(20, 0.8), closeTo(400 / (0.8 * Dynamics.g), 1e-9));
    expect(Dynamics.radiusM(1, 0.8), 0);
    expect(Dynamics.radiusM(20, 0.01), 0);
  });
}

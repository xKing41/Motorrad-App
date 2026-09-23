import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/services/crash_detector.dart';

/// Spielt einen Ablauf durch: [ms] ist die simulierte Uhr.
class Sim {
  Sim() {
    d = CrashDetector(onSuspectedCrash: () => alarms++);
  }
  late final CrashDetector d;
  int alarms = 0;
  int ms = 0;
  List<double> gravity = [0, 9.81, 0];

  /// [sec] Sekunden mit Tempo [kmh]; GPS einmal je Sekunde, Sensor 50 Hz.
  void ride(double kmh, double sec, {bool gps = true, bool shaking = false}) {
    final end = ms + (sec * 1000).round();
    while (ms < end) {
      ms += 20;
      d.feedGravity(gravity[0], gravity[1], gravity[2]);
      final g = shaking && (ms ~/ 20).isEven ? 1.6 : 1.0;
      d.feedAccel(gravity[0] * g, gravity[1] * g, gravity[2] * g, ms);
      if (gps && ms % 1000 == 0) d.feedSpeed(kmh, ms);
      if (ms % 200 == 0) d.tick(ms);
    }
  }

  void impact() {
    ms += 20;
    d.feedAccel(0, 50, 0, ms);
  }
}

void main() {
  test('Sturz: Aufprall, Motorrad liegt, Stillstand -> Alarm', () {
    final s = Sim()..ride(60, 20);
    s.impact();
    s.gravity = [9.81, 0, 0]; // Motorrad auf der Seite
    s.ride(0, 12);
    expect(s.alarms, 1);
  });

  test('Schlag beim Ausrollen, dann aufrecht an der Ampel -> kein Alarm', () {
    final s = Sim()..ride(50, 20);
    s.ride(15, 3);
    s.impact();
    s.ride(0, 30);
    expect(s.alarms, 0);
  });

  test('GPS nach dem Sturz weg: Sensor-Ruhe genuegt', () {
    final s = Sim()..ride(70, 20);
    s.impact();
    s.gravity = [0, -9.81, 0]; // Handy liegt kopfueber
    s.ride(0, 12, gps: false);
    expect(s.alarms, 1);
  });

  test('ohne GPS, aber Handy wird noch bewegt -> noch kein Alarm', () {
    final s = Sim()..ride(70, 20);
    s.impact();
    s.gravity = [9.81, 0, 0];
    s.ride(0, 12, gps: false, shaking: true);
    expect(s.alarms, 0);
  });

  test('nie schnell gefahren (Handy faellt im Stand) -> kein Alarm', () {
    final s = Sim()..ride(10, 20);
    s.impact();
    s.gravity = [9.81, 0, 0];
    s.ride(0, 12);
    expect(s.alarms, 0);
  });

  test('nach dem Aufprall weitergefahren -> kein Alarm', () {
    final s = Sim()..ride(60, 20);
    s.impact();
    s.gravity = [9.81, 0, 0];
    s.ride(40, 12);
    expect(s.alarms, 0);
  });
}

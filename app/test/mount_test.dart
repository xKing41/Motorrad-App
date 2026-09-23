import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/services/mount.dart';

/// Schwerkraft (Gegenkraft, wie der Sensor sie misst) im Handy-System,
/// wenn das Motorrad um [leanDeg] nach rechts liegt. [frame] beschreibt,
/// wie das Handy montiert ist.
List<double> gravityAt(MountFrame frame, double leanDeg) {
  final a = leanDeg * math.pi / 180;
  // Welt-"oben" im Motorrad-System: bei Rechtslage kippt oben nach links.
  final upBike = math.cos(a), rightBike = -math.sin(a);
  return [
    for (var i = 0; i < 3; i++)
      9.81 * (upBike * frame.up[i] + rightBike * frame.right[i]),
  ];
}

void main() {
  final mounts = {
    'hochkant': [0.0, 9.81, 0.0],
    'hochkant, nach hinten gekippt': [0.0, 8.5, 4.9],
    'quer, Oberkante links': [9.81, 0.0, 0.0],
    'quer, Oberkante rechts': [-9.81, 0.0, 0.0],
    'flach im Tankrucksack': [0.0, 0.0, 9.81],
    'flach, leicht aufgestellt': [0.0, 3.0, 9.3],
  };

  for (final e in mounts.entries) {
    test('Montage ${e.key}: Schraeglage stimmt', () {
      final g = e.value;
      final f = MountFrame.fromGravity(g[0], g[1], g[2])!;
      expect(f.rollDeg(g[0], g[1], g[2]), closeTo(0, 1e-6));
      for (final lean in [-45.0, -20.0, 15.0, 40.0]) {
        final gl = gravityAt(f, lean);
        expect(f.rollDeg(gl[0], gl[1], gl[2]), closeTo(lean, 1e-6));
      }
      // Vorn steht senkrecht auf oben und rechts.
      double dot(List<double> a, List<double> b) =>
          a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
      expect(dot(f.fwd, f.up), closeTo(0, 1e-9));
      expect(dot(f.fwd, f.right), closeTo(0, 1e-9));
      expect(dot(f.fwd, f.fwd), closeTo(1, 1e-9));
    });
  }

  test('hochkant ergibt dieselben Achsen wie vorher', () {
    final f = MountFrame.fromGravity(0, 9.81, 0)!;
    expect(f.fwd, [0, 0, -1]);
    expect(f.right, [1, 0, 0]);
  });

  test('flach: vorn ist die Oberkante des Handys', () {
    final f = MountFrame.fromGravity(0, 0, 9.81)!;
    expect(f.fwd[1], closeTo(1, 1e-9));
  });

  test('Drehung um die Laengsachse nach rechts ist positiv', () {
    for (final g in mounts.values) {
      final f = MountFrame.fromGravity(g[0], g[1], g[2])!;
      // Winkelgeschwindigkeit um "vorn" mit 1 rad/s.
      expect(f.rollRate(f.fwd[0], f.fwd[1], f.fwd[2]), closeTo(1, 1e-9));
    }
  });

  test('unbrauchbarer Wert (Handy in Bewegung)', () {
    expect(MountFrame.fromGravity(0, 1, 0), isNull);
    expect(MountFrame.fromGravity(0, 30, 0), isNull);
  });

  test('speichern und laden', () {
    final f = MountFrame.fromGravity(9.81, 0, 0)!;
    final g = MountFrame.fromList(f.toList())!;
    expect(g.fwd, f.fwd);
  });
}

import 'dart:math' as math;

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  KURVEN-VORWARNUNG
//
//  Aus der Linie der Route wird fuer jede Stelle der Kurvenradius
//  berechnet. Enge Kurven (Spitzkehren, zumachende Kurven hinter einer
//  Kuppe) werden vorab erkannt. Gewarnt wird nur, wenn das aktuelle Tempo
//  deutlich ueber dem liegt, mit dem die Kurve entspannt zu fahren ist -
//  wer ohnehin passend unterwegs ist, bekommt keine Ansage.
//
//  Richttempo: Querbeschleunigung 0,35 g (sportlich-entspanntes
//  Landstrassenfahren, Schraeglage um 20 Grad). Bremsweg mit 3 m/s²
//  (sanftes Bremsen) plus 2,5 s Vorlauf.
//
//  Grenzen: Die Linie aus OSM ist nicht vermessen genau; bei sehr kurzen
//  Radien wird der Wert eher unter- als ueberschaetzt. Die Warnung ist
//  ein Hinweis, kein Ersatz fuer den Blick auf die Strasse.
// ---------------------------------------------------------------------------

class RoadCurve {
  const RoadCurve({
    required this.startM,
    required this.apexM,
    required this.endM,
    required this.minRadiusM,
    required this.angleDeg,
    required this.right,
  });

  /// Beginn, engste Stelle und Ende (m ab Start der Route).
  final double startM;
  final double apexM;
  final double endM;
  final double minRadiusM;

  /// Gesamte Richtungsaenderung (Grad).
  final double angleDeg;
  final bool right;

  bool get hairpin => angleDeg >= 140 && minRadiusM < 30;

  /// Richttempo (m/s) fuer [latG] Querbeschleunigung.
  double adviseMs({double latG = 0.35}) =>
      math.sqrt(latG * 9.81 * minRadiusM);

  int get adviseKmh => (adviseMs() * 3.6 / 5).round() * 5;

  String get label {
    final side = right ? 'Rechtskurve' : 'Linkskurve';
    if (hairpin) return right ? 'Spitzkehre rechts' : 'Spitzkehre links';
    return 'Enge $side';
  }

  @override
  String toString() =>
      'RoadCurve(${startM.round()}-${endM.round()}, r=${minRadiusM.round()}, '
      '${angleDeg.round()}°, ${right ? 'R' : 'L'})';
}

class CurveFinder {
  /// Schrittweite fuer die Auswertung (m).
  static const double step = 10;

  /// Ab diesem Radius gilt eine Stelle als "eng".
  static const double tightRadiusM = 70;

  /// Mindest-Richtungsaenderung, damit es eine Kurve ist (keine Knicke
  /// in der Linie).
  static const double minAngleDeg = 60;

  /// Enge Kurven der Route. [skipNear]: Stellen (m ab Start), an denen
  /// ohnehin abgebogen wird - dort ist die Ecke eine Kreuzung und wird
  /// schon angesagt.
  static List<RoadCurve> find(List<RoutePoint> pts,
      {List<double> skipNear = const [], double skipM = 40}) {
    if (pts.length < 3) return const [];
    final r = resample(pts, step);
    if (r.length < 5) return const [];
    // Richtungsaenderung je Stelle ueber +-20 m, daraus Radius.
    final n = r.length;
    final turn = List<double>.filled(n, 0); // Grad, + = rechts
    final radius = List<double>.filled(n, double.infinity);
    for (var i = 2; i < n - 2; i++) {
      final a = bearingDeg(r[i - 2], r[i]);
      final b = bearingDeg(r[i], r[i + 2]);
      final d = angleDiff(a, b);
      turn[i] = d;
      final rad = d.abs() * math.pi / 180;
      if (rad > 1e-3) radius[i] = 2 * step / rad;
    }
    final skip = [...skipNear]..sort();
    bool nearTurn(double m) {
      for (final s in skip) {
        if ((s - m).abs() <= skipM) return true;
        if (s > m + skipM) break;
      }
      return false;
    }

    final out = <RoadCurve>[];
    var i = 2;
    while (i < n - 2) {
      if (radius[i] >= tightRadiusM) {
        i++;
        continue;
      }
      final sign = turn[i].sign;
      // Kurvenbereich: gleiche Richtung, Radius unter dem Doppelten
      // der Schwelle (Ein- und Auslauf gehoeren dazu).
      var a = i, b = i;
      while (a > 2 &&
          turn[a - 1].sign == sign &&
          radius[a - 1] < tightRadiusM * 2) {
        a--;
      }
      while (b < n - 3 &&
          turn[b + 1].sign == sign &&
          radius[b + 1] < tightRadiusM * 2) {
        b++;
      }
      // Jede Stelle misst die Aenderung ueber 20 m (zwei Schritte);
      // die Summe zaehlt also alles doppelt.
      var angle = 0.0;
      var minR = double.infinity;
      var apex = a;
      for (var k = a; k <= b; k++) {
        angle += turn[k].abs() / 2;
        if (radius[k] < minR) {
          minR = radius[k];
          apex = k;
        }
      }
      final startM = a * step, endM = b * step, apexM = apex * step;
      if (angle >= minAngleDeg && !nearTurn(apexM)) {
        out.add(RoadCurve(
          startM: startM,
          apexM: apexM,
          endM: endM,
          minRadiusM: minR,
          angleDeg: math.min(angle, 200),
          right: sign > 0,
        ));
      }
      i = b + 1;
    }
    return out;
  }

  /// Muss jetzt gewarnt werden? [distM]: Entfernung bis zum Beginn der
  /// Kurve, [speedMs]: aktuelles Tempo.
  static bool shouldWarn(RoadCurve c, double distM, double speedMs) {
    final adv = c.adviseMs();
    // Wer schon passend langsam ist, braucht keine Warnung.
    if (speedMs * 3.6 < adv * 3.6 + 12) return false;
    final brake = (speedMs * speedMs - adv * adv) / (2 * 3.0);
    final lead = brake + speedMs * 2.5;
    return distM <= lead + 30 && distM >= 0;
  }
}

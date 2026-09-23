import 'dart:math' as math;

import '../models/ride.dart';
import 'dynamics.dart';

// ---------------------------------------------------------------------------
//  TIEFENAUSWERTUNG EINER FAHRT
//
//  Der Markt trennt sich in Navi-Apps und Analyse-Apps. Navigieren koennen
//  viele; auswerten, WIE gefahren wurde, kaum jemand richtig. Genau dort
//  liegt unsere Stelle: Schraeglage pro Punkt liegt schon auf der Platte,
//  wurde bisher aber nur als Maximalwert gezeigt.
//
//  Alles hier wird aus bereits aufgezeichneten Daten gerechnet. Es muss
//  nichts zusaetzlich gespeichert werden, und alte Fahrten lassen sich
//  nachtraeglich auswerten.
// ---------------------------------------------------------------------------

const double _g = 9.81;

/// Ein Punkt im Kammschen Kreis: Laengs- und Querbeschleunigung
/// zum selben Zeitpunkt.
class KammPoint {
  const KammPoint(this.latG, this.longG);

  /// Querbeschleunigung, immer positiv (Betrag).
  final double latG;

  /// Laengsbeschleunigung. Positiv = beschleunigen, negativ = bremsen.
  final double longG;

  /// Laenge des Summenvektors - das ist die Groesse, die der Reifen
  /// insgesamt aufbringen muss.
  double get total => math.sqrt(latG * latG + longG * longG);
}

/// Zeit je Schraeglagen-Bereich, in 5-Grad-Schritten.
class LeanHistogram {
  LeanHistogram(this.bucketSeconds);

  /// Index 0 = 0-5 Grad, Index 1 = 5-10 Grad, ... Index 11 = 55 Grad und mehr.
  final List<double> bucketSeconds;

  static const int buckets = 12;
  static const double step = 5;

  double get totalSeconds =>
      bucketSeconds.fold<double>(0, (a, b) => a + b);

  double get peakSeconds =>
      bucketSeconds.fold<double>(0, (a, b) => b > a ? b : a);

  /// Untergrenze des Bereichs in Grad.
  static double lowerBound(int i) => i * step;

  /// Anteil der Zeit ab [fromDeg] Schraeglage.
  double shareAbove(double fromDeg) {
    final total = totalSeconds;
    if (total <= 0) return 0;
    var s = 0.0;
    for (var i = 0; i < bucketSeconds.length; i++) {
      if (lowerBound(i) >= fromDeg) s += bucketSeconds[i];
    }
    return s / total;
  }
}

/// Bewertung des Fahrstils.
///
/// WICHTIG - und das ist eine bewusste Entscheidung gegen den Markt:
/// Mehr Schraeglage gibt hier KEINE Punkte. Eine App, die fuer tiefere
/// Schraeglage belohnt, treibt Leute auf oeffentlichen Strassen ins
/// Risiko. Bewertet wird stattdessen, was gute Fahrer wirklich
/// ausmacht: gleichmaessige Schraeglagenaufbau, beide Seiten gleich
/// sicher, und nicht mitten in der Kurve am Bremshebel reissen.
class RideScore {
  const RideScore({
    required this.smoothness,
    required this.balance,
    required this.brakeDiscipline,
    required this.total,
  });

  /// 0-100: Wie gleichmaessig die Schraeglage aufgebaut wurde.
  final double smoothness;

  /// 0-100: Wie aehnlich Links- und Rechtskurven gefahren wurden.
  final double balance;

  /// 0-100: Wie selten gebremst wurde, waehrend das Motorrad schon
  /// deutlich in Schraeglage war.
  final double brakeDiscipline;

  /// Gewichteter Gesamtwert 0-100.
  final double total;

  String get grade {
    if (total >= 85) return 'SEHR RUND';
    if (total >= 70) return 'RUND';
    if (total >= 55) return 'BRAUCHBAR';
    if (total >= 40) return 'UNRUHIG';
    return 'HEKTISCH';
  }
}

/// Ergebnis der Auswertung einer kompletten Fahrt.
class RideAnalysis {
  RideAnalysis({
    required this.corners,
    required this.histogram,
    required this.kamm,
    required this.score,
    required this.curvesPerKm,
    required this.maxCombinedG,
    required this.leanBalanceDeg,
    required this.tightestRadiusM,
  });

  final List<Corner> corners;
  final LeanHistogram histogram;
  final List<KammPoint> kamm;
  final RideScore score;

  /// Kurven je Kilometer - das Mass fuer "wie kurvig war die Tour".
  final double curvesPerKm;

  /// Groesster Summenvektor aus Laengs- und Querbeschleunigung.
  final double maxCombinedG;

  /// Unterschied zwischen der besten Links- und Rechtsschraeglage.
  /// Ein grosser Wert zeigt die schwaechere Seite.
  final double leanBalanceDeg;

  /// Engster gefahrener Kurvenradius in Metern (Schaetzung).
  final double tightestRadiusM;

  bool get isEmpty => corners.isEmpty && histogram.totalSeconds <= 0;

  // -----------------------------------------------------------------
  /// Rechnet alles aus einem aufgezeichneten Track.
  static RideAnalysis of(List<TrackPoint> track) {
    final corners = detectCorners(track);
    final buckets = List<double>.filled(LeanHistogram.buckets, 0);
    final kamm = <KammPoint>[];

    double distM = 0;
    double jerkSum = 0; // Summe der Schraeglagenaenderung je Sekunde
    int jerkCount = 0;
    double maxCombined = 0;
    double brakeInLeanSec = 0; // Zeit mit Bremsen in Schraeglage
    double leanTimeSec = 0; // Zeit ueberhaupt in Schraeglage

    for (var i = 1; i < track.length; i++) {
      final a = track[i - 1];
      final b = track[i];
      final dt = (b.tMs - a.tMs) / 1000.0;

      // Ausreisser ueberspringen: Pause, GPS-Luecke, Uhrensprung.
      if (dt <= 0 || dt > 5) continue;

      distM += distanceMeters(a.lat, a.lon, b.lat, b.lon);

      // Stand (Ampel, Seitenstaender) gehoert nicht in die Auswertung -
      // sonst dominieren Wartezeiten das Histogramm.
      if (b.speedMs < cornerMinSpeedMs) continue;
      final absLean = b.lean.abs();

      // --- Histogramm: Zeit je Schraeglagenbereich ---
      var bi = (absLean / LeanHistogram.step).floor();
      if (bi < 0) bi = 0;
      if (bi >= LeanHistogram.buckets) bi = LeanHistogram.buckets - 1;
      buckets[bi] += dt;

      // --- Kammscher Kreis ---
      // Quer- und Laengsbeschleunigung wie gemessen. Aeltere Fahrten ohne
      // Messwert: quer aus der Schraeglage (nur in gleichmaessigen Kurven
      // richtig), laengs aus der Tempoaenderung.
      final latG = b.latG ?? Dynamics.lateralGFromLean(absLean);
      final longG = (b.longG ?? (b.speedMs - a.speedMs) / dt / _g)
          .clamp(-1.5, 1.5)
          .toDouble();
      final p = KammPoint(latG, longG);
      if (p.total > maxCombined) maxCombined = p.total;
      // Nur bei sinnvoller Fahrt sammeln, sonst verwaessert Stillstand
      // das Bild.
      if (b.speedMs > 2) kamm.add(p);

      // --- Gleichmaessigkeit ---
      // Auch der vorige Punkt muss in Fahrt sein, sonst zaehlt das
      // Aufrichten vom Seitenstaender als hektische Bewegung.
      if (a.speedMs < cornerMinSpeedMs) continue;
      jerkSum += (b.lean - a.lean).abs() / dt;
      jerkCount++;

      // --- Bremsen in Schraeglage ---
      // Aus der Tempoaenderung, nicht aus dem Sensorwert: Der ist ein
      // Momentwert und schwankt mit jeder Bodenwelle.
      if (absLean > 20) {
        leanTimeSec += dt;
        final decel = (b.speedMs - a.speedMs) / dt / _g;
        if (decel < -0.25) brakeInLeanSec += dt;
      }
    }

    final histogram = LeanHistogram(buckets);

    // ---------------- Bewertung ----------------
    // Gleichmaessigkeit: 8 Grad je Sekunde gelten als sehr rund,
    // 35 Grad je Sekunde als hektisch.
    final avgJerk = jerkCount > 0 ? jerkSum / jerkCount : 0.0;
    final smoothness =
        (100 - (avgJerk - 8) / (35 - 8) * 100).clamp(0.0, 100.0).toDouble();

    // Balance: Unterschied der besten Seite. 0 Grad = perfekt,
    // 15 Grad Unterschied = deutliche schwache Seite.
    double bestL = 0, bestR = 0;
    for (final c in corners) {
      if (c.direction < 0 && c.maxLean > bestL) bestL = c.maxLean;
      if (c.direction > 0 && c.maxLean > bestR) bestR = c.maxLean;
    }
    final diff = (bestL - bestR).abs();
    final balance = (100 - diff / 15 * 100).clamp(0.0, 100.0).toDouble();

    // Bremsdisziplin: Anteil der Schraeglagenzeit mit Bremseingriff.
    final brakeShare = leanTimeSec > 0 ? brakeInLeanSec / leanTimeSec : 0.0;
    final brakeDiscipline =
        (100 - brakeShare * 300).clamp(0.0, 100.0).toDouble();

    // Ohne Kurven gibt es nichts zu bewerten - dann bleibt alles bei 0,
    // statt eine Traumnote fuer eine Autobahnfahrt auszugeben.
    final hasContent = corners.isNotEmpty && leanTimeSec > 2;
    final total = hasContent
        ? (smoothness * 0.45 + balance * 0.2 + brakeDiscipline * 0.35)
            .clamp(0.0, 100.0)
            .toDouble()
        : 0.0;

    // ---------------- Radien ----------------
    double tightest = double.infinity;
    for (final c in corners) {
      final r = radiusOf(c);
      if (r > 0 && r < tightest) tightest = r;
    }

    final km = distM / 1000;
    return RideAnalysis(
      corners: corners,
      histogram: histogram,
      kamm: kamm,
      score: RideScore(
        smoothness: hasContent ? smoothness : 0,
        balance: hasContent ? balance : 0,
        brakeDiscipline: hasContent ? brakeDiscipline : 0,
        total: total,
      ),
      curvesPerKm: km > 0.2 ? corners.length / km : 0,
      maxCombinedG: maxCombined,
      leanBalanceDeg: diff,
      tightestRadiusM: tightest.isFinite ? tightest : 0,
    );
  }

  /// Radius einer Kurve in Metern: r = v^2 / a am Scheitel.
  ///
  /// Mit gemessener Querbeschleunigung direkt; bei aelteren Fahrten aus
  /// der Schraeglage (mit Reifenkorrektur). Tempo und Beschleunigung
  /// stammen vom SELBEN Moment. Gibt 0 zurueck, wenn keine sinnvolle
  /// Rechnung moeglich ist.
  static double radiusOf(Corner c) {
    final v = (c.apexSpeedKmh > 0 ? c.apexSpeedKmh : c.minSpeedKmh) / 3.6;
    final a = c.apexLatG ?? Dynamics.lateralGFromLean(c.maxLean);
    return Dynamics.radiusM(v, a);
  }

}

import '../models/ride.dart';
import 'dynamics.dart';
import 'ride_analysis.dart';

// ---------------------------------------------------------------------------
//  PERSOENLICHE KURVENANALYSE
//
//  Eine einzelne Fahrt sagt wenig - Strasse, Wetter und Tagesform
//  schwanken. Ueber viele Fahrten zeigen sich Muster: Die meisten Fahrer
//  legen sich in eine Richtung deutlich weniger tief, bremsen in engen
//  Kurven bis zum Scheitel oder fahren weite Boegen zu vorsichtig. Das
//  wird hier aus allen Kurven der letzten Fahrten ausgewertet - nach
//  Richtung und Kurvenradius getrennt, damit nicht Aepfel (Spitzkehre)
//  mit Birnen (Autobahnkurve) verglichen werden.
//
//  Keine Rangliste, kein "schneller ist besser": Die Hinweise zielen auf
//  Gleichmaessigkeit und saubere Linie.
// ---------------------------------------------------------------------------

enum RadiusClass { tight, medium, wide }

extension RadiusClassX on RadiusClass {
  String get label => switch (this) {
        RadiusClass.tight => 'Eng (unter 60 m)',
        RadiusClass.medium => 'Mittel (60-150 m)',
        RadiusClass.wide => 'Weit (über 150 m)',
      };

  /// "Enge", "Mittlere", "Weite" (fuer "... Kurven").
  String get adjective => switch (this) {
        RadiusClass.tight => 'Enge',
        RadiusClass.medium => 'Mittlere',
        RadiusClass.wide => 'Weite',
      };

  static RadiusClass of(double r) => r < 60
      ? RadiusClass.tight
      : (r < 150 ? RadiusClass.medium : RadiusClass.wide);
}

/// Kennzahlen einer Gruppe von Kurven.
class CornerStats {
  CornerStats(this.count, this.avgLean, this.avgLatG, this.avgApexKmh,
      this.avgSpeedDrop);

  final int count;
  final double avgLean;
  final double avgLatG;
  final double avgApexKmh;

  /// Tempoverlust vom Kurveneingang bis zum Scheitel (0..1).
  final double avgSpeedDrop;

  static CornerStats? of(Iterable<Corner> cs) {
    final l = cs.toList();
    if (l.isEmpty) return null;
    double avg(double Function(Corner) f) =>
        l.fold<double>(0, (s, c) => s + f(c)) / l.length;
    return CornerStats(
      l.length,
      avg((c) => c.maxLean),
      avg((c) => c.apexLatG ?? Dynamics.lateralGFromLean(c.maxLean)),
      avg((c) => c.apexSpeedKmh > 0 ? c.apexSpeedKmh : c.minSpeedKmh),
      avg((c) => c.entrySpeedKmh > 5
          ? ((c.entrySpeedKmh -
                      (c.apexSpeedKmh > 0 ? c.apexSpeedKmh : c.minSpeedKmh)) /
                  c.entrySpeedKmh)
              .clamp(0.0, 1.0)
              .toDouble()
          : 0),
    );
  }
}

/// Eine Fahrt mit ihren Kurven - Eingabe fuer das Profil.
class RideCorners {
  RideCorners(this.summary, this.corners);
  final RideSummary summary;
  final List<Corner> corners;
}

class RiderProfile {
  RiderProfile({
    required this.rides,
    required this.corners,
    required this.left,
    required this.right,
    required this.byClass,
    required this.trend,
    required this.insights,
  });

  final int rides;
  final int corners;
  final CornerStats? left;
  final CornerStats? right;

  /// Je Radiusklasse: (links, rechts).
  final Map<RadiusClass, (CornerStats?, CornerStats?)> byClass;

  /// Mittlere Schraeglage je Fahrt (aelteste zuerst) - fuer den Verlauf.
  final List<(DateTime, double)> trend;

  /// Hinweise in Klartext, wichtigste zuerst.
  final List<String> insights;

  /// Mindestzahl Kurven je Gruppe, damit ein Vergleich etwas aussagt.
  static const int minGroup = 8;

  static RiderProfile of(List<RideCorners> input) {
    final rides = [...input]
      ..sort((a, b) => a.summary.start.compareTo(b.summary.start));
    final all = [for (final r in rides) ...r.corners];
    final radius = {for (final c in all) c: RideAnalysis.radiusOf(c)};
    Iterable<Corner> dir(Iterable<Corner> cs, int d) =>
        cs.where((c) => c.direction == d);

    final byClass = <RadiusClass, (CornerStats?, CornerStats?)>{};
    for (final k in RadiusClass.values) {
      final cs = all.where((c) {
        final r = radius[c]!;
        return r > 0 && RadiusClassX.of(r) == k;
      });
      byClass[k] = (CornerStats.of(dir(cs, -1)), CornerStats.of(dir(cs, 1)));
    }

    final trend = <(DateTime, double)>[
      for (final r in rides)
        if (r.corners.length >= 5)
          (
            r.summary.start,
            r.corners.fold<double>(0, (s, c) => s + c.maxLean) /
                r.corners.length,
          ),
    ];

    final left = CornerStats.of(dir(all, -1));
    final right = CornerStats.of(dir(all, 1));
    return RiderProfile(
      rides: rides.length,
      corners: all.length,
      left: left,
      right: right,
      byClass: byClass,
      trend: trend,
      insights: _insights(left, right, byClass, trend),
    );
  }

  static List<String> _insights(
    CornerStats? left,
    CornerStats? right,
    Map<RadiusClass, (CornerStats?, CornerStats?)> byClass,
    List<(DateTime, double)> trend,
  ) {
    final out = <String>[];
    bool enough(CornerStats? s) => s != null && s.count >= minGroup;

    // 1. Seitenunterschied - in derselben Radiusklasse verglichen, sonst
    //    verfaelscht das Streckenprofil (z. B. mehr enge Linkskurven).
    for (final k in RadiusClass.values) {
      final (l, r) = byClass[k]!;
      if (!enough(l) || !enough(r)) continue;
      final diff = r!.avgLean - l!.avgLean;
      if (diff.abs() >= 4) {
        final weaker = diff > 0 ? 'links' : 'rechts';
        final stronger = diff > 0 ? 'rechts' : 'links';
        out.add('${k.adjective} Kurven: $weaker legst du dich '
            'im Schnitt ${diff.abs().round()}° weniger tief als $stronger. '
            'Häufig ist das Blickführung - bewusst weit durch die '
            '${diff > 0 ? 'Links' : 'Rechts'}kurven schauen.');
        break;
      }
    }

    // 2. Bremsen bis zum Scheitel in engen Kurven.
    final (tl, tr) = byClass[RadiusClass.tight]!;
    final tight = [tl, tr].whereType<CornerStats>().toList();
    final tightCount = tight.fold<int>(0, (s, x) => s + x.count);
    if (tightCount >= minGroup) {
      final drop = tight.fold<double>(0, (s, x) => s + x.avgSpeedDrop * x.count) /
          tightCount;
      if (drop >= 0.35) {
        out.add('In engen Kurven fällt dein Tempo bis zum Scheitel um '
            '${(drop * 100).round()} %. Früher und kürzer bremsen, dann '
            'gleichmäßig durch die Kurve rollen, bringt mehr Ruhe ins '
            'Fahrwerk.');
      }
    }

    // 3. Weite Kurven sehr vorsichtig (kaum Querbeschleunigung).
    final (wl, wr) = byClass[RadiusClass.wide]!;
    final wide = [wl, wr].whereType<CornerStats>().toList();
    final wideCount = wide.fold<int>(0, (s, x) => s + x.count);
    if (wideCount >= minGroup) {
      final g =
          wide.fold<double>(0, (s, x) => s + x.avgLatG * x.count) / wideCount;
      if (g < 0.2) {
        out.add('Weite Kurven fährst du sehr defensiv (im Schnitt '
            '${g.toStringAsFixed(2).replaceAll('.', ',')} g). Das ist '
            'kein Fehler - aber dort ist am meisten Reserve, um Schräglage '
            'in Ruhe zu üben.');
      }
    }

    // 4. Verlauf ueber die Fahrten.
    if (trend.length >= 6) {
      final n = trend.length ~/ 3;
      double avg(Iterable<(DateTime, double)> l) =>
          l.fold<double>(0, (s, x) => s + x.$2) / l.length;
      final early = avg(trend.take(n));
      final late = avg(trend.skip(trend.length - n));
      if (late - early >= 2) {
        out.add('Deine mittlere Schräglage ist über die letzten Fahrten von '
            '${early.round()}° auf ${late.round()}° gestiegen - du fährst '
            'sicherer durch die Kurven.');
      } else if (early - late >= 3) {
        out.add('Zuletzt fährst du weniger Schräglage als früher '
            '(${late.round()}° statt ${early.round()}°) - Wetter, andere '
            'Strecken oder bewusst ruhiger?');
      }
    }

    if (out.isEmpty && enough(left) && enough(right)) {
      out.add('Links und rechts fährst du gleichmäßig - '
          '${left!.avgLean.round()}° zu ${right!.avgLean.round()}° im Schnitt.');
    }
    return out;
  }
}

import 'dart:math' as math;

// ---------------------------------------------------------------------------
//  FAHRPHYSIK
//
//  Alle Formeln an einer Stelle, damit sie geprueft werden koennen.
//
//  Grundlage: In einer Kurve wirken auf Motorrad und Fahrer die
//  Schwerkraft (senkrecht) und die Querbeschleunigung a = v * Gierrate
//  (waagerecht). Die Linie vom Reifenaufstandspunkt zum Schwerpunkt zeigt
//  in Richtung der Summe beider - das ist die "effektive" Schraeglage:
//        tan(effektiv) = a / g
//
//  Zwei Dinge, die eine einfache App falsch macht:
//   1. Querbeschleunigung aus der Schraeglage ausrechnen (g * tan).
//      Das stimmt nur in einer gleichmaessigen Kurve. Im Stand, auf dem
//      Seitenstaender, beim Abwinkeln oder mit Hanging-off kommt Unsinn
//      heraus. Hier wird sie aus Tempo und Drehrate GEMESSEN.
//   2. Effektive Schraeglage mit der Schraeglage des Motorrads
//      gleichsetzen. Der Reifen ist rund: Mit zunehmender Schraeglage
//      wandert der Aufstandspunkt zur Kurveninnenseite, das Motorrad muss
//      um einige Grad TIEFER liegen als die effektive Linie. Bei 40 Grad
//      effektiv sind das mit einem 180er Hinterreifen rund 6 Grad.
// ---------------------------------------------------------------------------

class Dynamics {
  static const double g = 9.80665;

  /// Obergrenze fuer die Querbeschleunigung: Mehr als etwa 1,3 g schafft
  /// kein Strassenreifen - alles darueber ist Messrauschen.
  static const double maxLatG = 1.5;

  /// Radius des Reifenprofils (Rundung der Lauffläche) in m. Mittelwert
  /// aus Vorder- und Hinterreifen einer typischen Strassenmaschine.
  static const double tireProfileRadiusM = 0.08;

  /// Hoehe des gemeinsamen Schwerpunkts von Motorrad und Fahrer in m.
  static const double cogHeightM = 0.55;

  /// Gemessene Gierrate (rad/s, um die Hochachse des Motorrads - so
  /// misst sie ein mitgeneigtes Handy) und Tempo -> Sinus der effektiven
  /// Schraeglage. Um die Hochachse gemessen ist die Drehrate um cos(phi)
  /// kleiner als die echte - daher Sinus statt Tangens.
  static double _sinEff(double speedMs, double yawRate) =>
      (speedMs * yawRate / g).clamp(-0.999, 0.999).toDouble();

  /// Effektive Schraeglage in Grad (Vorzeichen wie die Gierrate).
  static double effectiveLeanDeg(double speedMs, double yawRate) =>
      math.asin(_sinEff(speedMs, yawRate)) * 180 / math.pi;

  /// Querbeschleunigung in g - gemessen, nicht aus der Schraeglage
  /// geschaetzt. a = v * Gierrate(Welt) = g * tan(effektiv).
  static double lateralG(double speedMs, double yawRate) {
    final s = _sinEff(speedMs, yawRate).abs();
    return math.min(maxLatG, s / math.sqrt(1 - s * s));
  }

  /// Schraeglage des Motorrads aus der effektiven Schraeglage, mit
  /// Korrektur fuer die Reifenbreite.
  ///
  /// Geometrie: Der Schwerpunkt liegt (h - t) ueber dem Mittelpunkt der
  /// Profilrundung, dieser t ueber dem Boden. Daraus folgt
  ///     phi = phi_eff + asin( t * sin(phi_eff) / (h - t) ).
  static double bikeLeanDeg(double effectiveDeg,
      {double t = tireProfileRadiusM, double h = cogHeightM}) {
    final e = effectiveDeg * math.pi / 180;
    final k = (t * math.sin(e.abs()) / (h - t)).clamp(0.0, 0.9);
    final corr = math.asin(k) * 180 / math.pi;
    return effectiveDeg + (effectiveDeg < 0 ? -corr : corr);
  }

  /// Umkehrung von [bikeLeanDeg]: effektive Schraeglage zur Schraeglage
  /// des Motorrads (fuer alte Fahrten ohne gemessene Querbeschleunigung).
  static double effectiveFromBikeDeg(double bikeDeg,
      {double t = tireProfileRadiusM, double h = cogHeightM}) {
    final p = bikeDeg.abs() * math.pi / 180;
    final eff = math.atan2((h - t) * math.sin(p), t + (h - t) * math.cos(p));
    final d = eff * 180 / math.pi;
    return bikeDeg < 0 ? -d : d;
  }

  /// Querbeschleunigung in g aus der Schraeglage des Motorrads - NUR fuer
  /// gleichmaessige Kurven und alte Fahrten ohne Messwert.
  static double lateralGFromLean(double bikeDeg) {
    final e = effectiveFromBikeDeg(bikeDeg).abs() * math.pi / 180;
    return math.min(maxLatG, math.tan(e));
  }

  /// Kurvenradius in m aus Tempo und Querbeschleunigung: r = v^2 / a.
  /// 0, wenn keine sinnvolle Rechnung moeglich ist.
  static double radiusM(double speedMs, double latG) {
    if (speedMs < 3 || latG < 0.05) return 0;
    final r = speedMs * speedMs / (latG * g);
    return (r > 3 && r < 2000) ? r : 0;
  }
}

/// Bauart des Motorrads - bestimmt die Schwerpunkthoehe mit Fahrer.
enum BikeType { sport, naked, touring, enduro, cruiser }

extension BikeTypeX on BikeType {
  String get label => switch (this) {
        BikeType.sport => 'Supersportler',
        BikeType.naked => 'Naked / Allrounder',
        BikeType.touring => 'Tourer',
        BikeType.enduro => 'Reiseenduro',
        BikeType.cruiser => 'Cruiser / Chopper',
      };

  /// Schwerpunkt von Motorrad und Fahrer ueber dem Boden (m).
  double get cogHeightM => switch (this) {
        BikeType.sport => 0.52,
        BikeType.naked => 0.55,
        BikeType.touring => 0.58,
        BikeType.enduro => 0.64,
        BikeType.cruiser => 0.50,
      };
}

/// Daten des eigenen Motorrads fuer die Schraeglagen-Rechnung.
class BikeProfile {
  const BikeProfile({
    this.type = BikeType.naked,
    this.frontWidthMm = 120,
    this.rearWidthMm = 180,
  });

  final BikeType type;
  final int frontWidthMm;
  final int rearWidthMm;

  /// Rundung der Laufflaeche: etwa die halbe Reifenbreite, gemittelt
  /// ueber beide Raeder (beide tragen das Motorrad).
  double get tireProfileRadiusM => (frontWidthMm + rearWidthMm) / 2 / 2 / 1000;

  double get cogHeightM => type.cogHeightM;

  double bikeLeanDeg(double effectiveDeg) => Dynamics.bikeLeanDeg(effectiveDeg,
      t: tireProfileRadiusM, h: cogHeightM);

  BikeProfile copyWith({BikeType? type, int? frontWidthMm, int? rearWidthMm}) =>
      BikeProfile(
        type: type ?? this.type,
        frontWidthMm: frontWidthMm ?? this.frontWidthMm,
        rearWidthMm: rearWidthMm ?? this.rearWidthMm,
      );

  List<String> toList() => [type.name, '$frontWidthMm', '$rearWidthMm'];

  static BikeProfile fromList(List<String>? v) {
    if (v == null || v.length != 3) return const BikeProfile();
    return BikeProfile(
      type: BikeType.values
          .firstWhere((t) => t.name == v[0], orElse: () => BikeType.naked),
      frontWidthMm: int.tryParse(v[1]) ?? 120,
      rearWidthMm: int.tryParse(v[2]) ?? 180,
    );
  }
}

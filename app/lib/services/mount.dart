import 'dart:math' as math;

/// Lage des Handys am Motorrad: welche Richtung im Handy "oben", "rechts"
/// und "vorn" ist.
///
/// Vorher ging die Messung stillschweigend von einem hochkant montierten
/// Handy aus (Bildschirm zum Fahrer). Quer am Lenker oder flach im
/// Tankrucksack kamen unbrauchbare Werte heraus - flach liegend sogar
/// Spruenge um 90 Grad, weil die "Oben"-Achse dann waagerecht liegt.
/// Jetzt wird die Lage beim Nullpunkt-Setzen aus der Schwerkraft
/// bestimmt:
///  * oben    = Richtung der Schwerkraft-Gegenkraft beim Kalibrieren
///  * rechts  = die Handy-Achse, die am ehesten waagerecht quer liegt
///              (hochkant/flach: x, quer: y)
///  * vorn    = oben x rechts
class MountFrame {
  const MountFrame(this.up, this.right, this.fwd);

  /// Einheitsvektoren im Koordinatensystem des Handys.
  final List<double> up;
  final List<double> right;
  final List<double> fwd;

  /// Hochkant, Bildschirm zum Fahrer - die Annahme bis zur Kalibrierung.
  static const portrait = MountFrame([0, 1, 0], [1, 0, 0], [0, 0, -1]);

  static double _dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  static List<double> _norm(List<double> v) {
    final n = math.sqrt(_dot(v, v));
    return n == 0 ? v : [v[0] / n, v[1] / n, v[2] / n];
  }

  static List<double> _cross(List<double> a, List<double> b) => [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
      ];

  /// Lage aus der gemessenen Schwerkraft (Beschleunigungssensor im
  /// Stand, m/s²). null, wenn der Wert unbrauchbar ist.
  static MountFrame? fromGravity(double gx, double gy, double gz) {
    final g = [gx, gy, gz];
    final n = math.sqrt(_dot(g, g));
    if (n < 5 || n > 15) return null;
    final u = _norm(g);
    // Quer-Achse waehlen. Liegt x fast senkrecht, ist das Handy quer
    // montiert - dann ist y die Querachse.
    final List<double> a;
    if (u[0].abs() < 0.7) {
      // Hochkant oder flach. Kopfueber hochkant: rechts ist -x.
      a = [u[1] < -0.5 ? -1.0 : 1.0, 0, 0];
    } else {
      // Quer: Oberkante links (x zeigt nach oben) -> rechts ist -y.
      a = [0, u[0] > 0 ? -1.0 : 1.0, 0];
    }
    final ad = _dot(a, u);
    final r = _norm([a[0] - ad * u[0], a[1] - ad * u[1], a[2] - ad * u[2]]);
    final f = _cross(u, r);
    return MountFrame(u, r, f);
  }

  /// Schraeglage aus der Schwerkraftrichtung in Grad, + = rechts.
  double rollDeg(double gx, double gy, double gz) {
    final g = [gx, gy, gz];
    return math.atan2(-_dot(g, right), _dot(g, up)) * 180 / math.pi;
  }

  /// Drehrate um die Laengsachse (rad/s) - die Aenderung der Schraeglage.
  double rollRate(double wx, double wy, double wz) => _dot([wx, wy, wz], fwd);

  /// Beschleunigung in Fahrtrichtung (m/s²), + = beschleunigen.
  double forward(double x, double y, double z) => _dot([x, y, z], fwd);

  List<double> toList() => [...up, ...right, ...fwd];

  static MountFrame? fromList(List<double>? v) {
    if (v == null || v.length != 9) return null;
    return MountFrame(v.sublist(0, 3), v.sublist(3, 6), v.sublist(6, 9));
  }
}

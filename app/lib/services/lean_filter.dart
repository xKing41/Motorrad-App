import 'dart:math' as math;

/// Kalman-Filter fuer die Schraeglage.
///
/// Warum nicht mehr der einfache Komplementaerfilter: Der mischt Gyroskop
/// und Referenz mit festen Anteilen. Hat das Gyroskop einen Nullpunkt-
/// fehler (jedes Handy-Gyroskop hat einen, und er wandert mit der
/// Temperatur), bleibt ein dauerhafter Fehler von "Drift x Zeitkonstante"
/// stehen - bei 1 Grad/s Drift rund 1,5 Grad.
///
/// Der Kalman-Filter schaetzt zwei Dinge gleichzeitig: die Schraeglage
/// UND den Nullpunktfehler des Gyroskops. Er lernt die Drift waehrend der
/// Fahrt und zieht sie ab. Ausserdem gewichtet er die Referenz je nach
/// ihrer Guete: Die GPS-Rechnung bei 100 km/h ist verlaesslicher als bei
/// 15 km/h, der Beschleunigungssensor im Stand verlaesslicher als in
/// Bewegung.
///
/// Zustand: x = [Schraeglage (Grad), Gyro-Nullpunkt (Grad/s)].
class LeanKalman {
  LeanKalman({
    this.qAngle = 1.5,
    this.qBias = 0.003,
  });

  /// Unsicherheit, die je Sekunde in die Schraeglage kommt (Grad^2/s) -
  /// Rauschen des Gyroskops.
  final double qAngle;

  /// Wie schnell der Nullpunkt wandern darf ((Grad/s)^2/s).
  final double qBias;

  double angle = 0;
  double bias = 0;

  // Kovarianz
  double _p00 = 100, _p01 = 0, _p10 = 0, _p11 = 1;

  /// Vorhersage mit der gemessenen Drehrate (Grad/s) ueber [dt] Sekunden.
  void predict(double rateDegS, double dt) {
    angle = _norm(angle + (rateDegS - bias) * dt);
    _p00 += dt * (dt * _p11 - _p01 - _p10 + qAngle);
    _p01 -= dt * _p11;
    _p10 -= dt * _p11;
    _p11 += qBias * dt;
  }

  /// Korrektur mit einer Referenz-Schraeglage (Grad) und ihrer
  /// Messunsicherheit [r] (Grad^2).
  void update(double measuredDeg, double r) {
    final y = _norm(measuredDeg - angle);
    final s = _p00 + r;
    final k0 = _p00 / s;
    final k1 = _p10 / s;
    angle = _norm(angle + k0 * y);
    bias += k1 * y;
    // Nullpunktfehler realistisch begrenzen.
    bias = bias.clamp(-5.0, 5.0).toDouble();
    final p00 = _p00, p01 = _p01;
    _p00 -= k0 * p00;
    _p01 -= k0 * p01;
    _p10 -= k1 * p00;
    _p11 -= k1 * p01;
  }

  /// Auf einen Winkel setzen (Nullpunkt, Neustart).
  void reset(double deg) {
    angle = deg;
    _p00 = 1;
    _p01 = 0;
    _p10 = 0;
  }

  /// Aktuelle Unsicherheit der Schraeglage (Grad, 1 Sigma).
  double get sigma => math.sqrt(math.max(0, _p00));

  static double _norm(double a) {
    a = (a + 180) % 360;
    if (a < 0) a += 360;
    return a - 180;
  }

  /// Messunsicherheit der GPS-Referenz (Grad^2): bei wenig Tempo
  /// schlechter, weil dann das Rauschen der Drehrate und die Ungenauigkeit
  /// des GPS-Tempos staerker durchschlagen.
  static double rGps(double speedMs) {
    final v = math.max(speedMs, 3.0);
    // 3 Grad bei 25 m/s, 6 Grad bei 8 m/s ...
    final sigma = 2.5 + 30 / v;
    return sigma * sigma;
  }

  /// Messunsicherheit des Beschleunigungssensors (Grad^2): im Stand gut,
  /// in Bewegung (Kurve ohne GPS, Bodenwellen) schlecht.
  static double rAccel({required bool still}) => still ? 4 : 100;
}

/// Erkennt Stillstand und misst dann den Nullpunkt des Gyroskops in allen
/// drei Achsen neu - an jeder Ampel. Ein falscher Nullpunkt verfaelscht
/// sonst auch die Drehrate um die Hochachse und damit Kurven-G und die
/// GPS-Referenz der Schraeglage.
class GyroBiasTracker {
  /// Wie lange es ruhig sein muss, bevor gemessen wird.
  static const double settleSec = 1.5;

  /// Ruhe: Drehrate unter 3 Grad/s, Beschleunigung nahe 1 g.
  static const double maxRate = 0.05; // rad/s
  static const double maxAccelDev = 0.06; // g

  double bx = 0, by = 0, bz = 0;
  bool hasBias = false;

  double _stillSec = 0;
  double _sx = 0, _sy = 0, _sz = 0;
  int _n = 0;

  bool get isStill => _stillSec >= settleSec;

  /// Rohwerte des Gyroskops (rad/s), Betrag der Beschleunigung (g),
  /// ob laut GPS gefahren wird.
  void feed(double gx, double gy, double gz, double accelG, double dt,
      {required bool moving}) {
    final rate = math.sqrt(gx * gx + gy * gy + gz * gz);
    final quiet = !moving &&
        (accelG - 1).abs() < maxAccelDev &&
        (rate < maxRate || (hasBias && _dev(gx, gy, gz) < maxRate));
    if (!quiet) {
      _stillSec = 0;
      _sx = _sy = _sz = 0;
      _n = 0;
      return;
    }
    _stillSec += dt;
    if (_stillSec < settleSec) return;
    _sx += gx;
    _sy += gy;
    _sz += gz;
    _n++;
    // Nach 50 Werten (1 s) uebernehmen, weich eingeblendet.
    if (_n >= 50) {
      final mx = _sx / _n, my = _sy / _n, mz = _sz / _n;
      const k = 0.5;
      if (!hasBias) {
        bx = mx;
        by = my;
        bz = mz;
      } else {
        bx += k * (mx - bx);
        by += k * (my - by);
        bz += k * (mz - bz);
      }
      hasBias = true;
      _sx = _sy = _sz = 0;
      _n = 0;
    }
  }

  double _dev(double gx, double gy, double gz) {
    final dx = gx - bx, dy = gy - by, dz = gz - bz;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }
}

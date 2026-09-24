import 'dart:math' as math;

import '../models/route_plan.dart';
import 'geo.dart';
import 'speed_limits.dart';

// ---------------------------------------------------------------------------
//  PROBEFAHRT (SIMULATION)
//
//  Faehrt eine Route mit einem virtuellen GPS ab - zum Testen am
//  Schreibtisch: Karte, Abbiegeansagen, Kurvenwarnungen, Tempolimit,
//  Stopps, Verfahren und Neuberechnung laufen genau wie auf der Strasse.
//
//  Das Tempo ist realistisch: In Kurven so schnell, wie es 0,3 g
//  Querbeschleunigung erlauben (entspanntes Landstrassentempo), sonst
//  bis zum Tempolimit (oder 100 km/h, wenn unbekannt). Davor wird mit
//  3 m/s² gebremst, danach mit 2 m/s² beschleunigt - wie ein Fahrer,
//  der vorausschauend faehrt.
// ---------------------------------------------------------------------------

class SimFix {
  const SimFix(this.point, this.speedMs, this.heading);
  final RoutePoint point;
  final double speedMs;
  final double heading;
}

class DriveSimulator {
  DriveSimulator({
    this.maxKmh = 100,
    this.latG = 0.3,
    this.accel = 2.0,
    this.decel = 3.0,
  });

  /// Hoechsttempo, wenn kein Tempolimit bekannt ist.
  final double maxKmh;
  final double latG;
  final double accel;
  final double decel;

  static const double step = 10;

  List<RoutePoint> _pts = const [];
  List<double> _cum = const [];
  List<double> _profile = const []; // m/s je 10 m
  List<SpeedLimit> _limits = const [];

  double along = 0;
  double speed = 0;
  RoutePoint? _pos;
  double _heading = 0;

  /// Abweichung von der Route ("Verfahren"): Reststrecke und Richtung.
  double _detourLeftM = 0;
  double _detourHeading = 0;

  bool get detouring => _detourLeftM > 0;
  RoutePoint? get position => _pos;
  bool get finished => _pts.isNotEmpty && along >= _cum.last - 1 && !detouring;
  double get totalM => _cum.isEmpty ? 0 : _cum.last;
  List<double> get profile => _profile;

  /// Route setzen - auch nach einer Neuberechnung unterwegs. Liegt die
  /// aktuelle Position auf der neuen Linie, geht es von dort weiter.
  void setRoute(List<RoutePoint> pts, {List<SpeedLimit>? limits}) {
    if (identical(pts, _pts) && limits == null) return;
    // Neue Linie (Neuberechnung nach dem Verfahren): Abweichung beenden,
    // auf der neuen Route weiter.
    if (!identical(pts, _pts)) _detourLeftM = 0;
    _pts = pts;
    if (limits != null) _limits = limits;
    _cum = cumulativeDistances(pts);
    _profile = speedProfile(pts, _limits);
    final p = _pos;
    if (p != null && pts.length >= 2) {
      final hit = projectOnPolyline(p, pts, _cum);
      along = hit?.alongM ?? 0;
    } else {
      along = 0;
      _pos = pts.isNotEmpty ? pts.first : null;
    }
  }

  /// Tempolimits nachreichen (kommen asynchron).
  void setLimits(List<SpeedLimit> limits) {
    _limits = limits;
    if (_pts.length >= 2) _profile = speedProfile(_pts, limits);
  }

  /// Zieltempo je 10 m: Kurve, Tempolimit, Bremsen und Beschleunigen.
  List<double> speedProfile(List<RoutePoint> pts, List<SpeedLimit> limits) {
    if (pts.length < 2) return const [];
    final r = resample(pts, step);
    final n = r.length;
    final v = List<double>.filled(n, maxKmh / 3.6);
    for (var i = 0; i < n; i++) {
      // Kurvenradius aus der Richtungsaenderung ueber +-20 m.
      if (i >= 2 && i < n - 2) {
        final d = angleDiff(bearingDeg(r[i - 2], r[i]), bearingDeg(r[i], r[i + 2]))
            .abs();
        final rad = d * math.pi / 180;
        if (rad > 1e-3) {
          final radius = 2 * step / rad;
          v[i] = math.min(v[i], math.sqrt(latG * 9.81 * radius));
        }
      }
      final l = limitAt(limits, i * step);
      if (l != null && !l.isUnlimited) v[i] = math.min(v[i], l.kmh / 3.6);
      v[i] = math.max(v[i], 4); // Schritttempo in Spitzkehren
    }
    v[0] = 0;
    v[n - 1] = 0;
    // Vorausschauend bremsen (von hinten nach vorn) ...
    for (var i = n - 2; i >= 0; i--) {
      v[i] = math.min(v[i], math.sqrt(v[i + 1] * v[i + 1] + 2 * decel * step));
    }
    // ... und sanft beschleunigen (von vorn nach hinten).
    for (var i = 1; i < n; i++) {
      v[i] = math.min(v[i], math.sqrt(v[i - 1] * v[i - 1] + 2 * accel * step));
    }
    return v;
  }

  double _targetAt(double m) {
    if (_profile.isEmpty) return 0;
    final i = (m / step).clamp(0, _profile.length - 1).toDouble();
    final a = i.floor(), b = math.min(a + 1, _profile.length - 1);
    final t = i - a;
    // Am Start aus dem Stand anfahren (Profil beginnt bei 0).
    return math.max(_profile[a] * (1 - t) + _profile[b] * t,
        m < 1 && !finished ? 1.5 : 0);
  }

  /// Von der Route abweichen: [lengthM] weit in einem Winkel davon weg
  /// (wie falsch abgebogen).
  void detour({double lengthM = 400, double angle = 70}) {
    if (_pts.length < 2) return;
    _detourLeftM = lengthM;
    _detourHeading = (_heading + angle) % 360;
  }

  /// Eine Zeitscheibe weiterfahren.
  SimFix step1(double dt) {
    final p = _pos;
    if (p == null || _pts.length < 2) {
      return SimFix(p ?? const RoutePoint(0, 0), 0, _heading);
    }
    if (detouring) {
      speed = math.min(speed, 40 / 3.6);
      if (speed < 5) speed = 5;
      final d = math.min(_detourLeftM, speed * dt);
      _pos = destinationPoint(p, _detourHeading, d);
      _heading = _detourHeading;
      _detourLeftM -= d;
      if (_detourLeftM <= 0) speed = 0; // stehen bleiben, bis neu berechnet
      return SimFix(_pos!, speed, _heading);
    }
    final target = _targetAt(along);
    speed = target >= speed
        ? math.min(target, speed + accel * dt)
        : math.max(target, speed - decel * dt);
    along = math.min(_cum.last, along + speed * dt);
    final np = pointAlong(_pts, _cum, along);
    final ahead = pointAlong(_pts, _cum, math.min(_cum.last, along + 15));
    if (dist(np, ahead) > 1) _heading = bearingDeg(np, ahead);
    _pos = np;
    if (along >= _cum.last - 1) speed = 0;
    return SimFix(np, speed, _heading);
  }
}

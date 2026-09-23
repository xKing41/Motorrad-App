import 'dart:math' as math;

import '../models/route_plan.dart';
import 'geo.dart';

/// Fluessige Position fuer die Kartenanzeige.
///
/// Das GPS liefert eine Position je Sekunde. Wird die Karte nur dann
/// bewegt, springt sie bei 100 km/h jede Sekunde um 28 Meter - das wirkt
/// ruckelig. Grosse Navis rechnen zwischen den Messungen weiter: mit
/// Tempo und Richtung, und bei einer Route AUF der Route (so bleibt der
/// Pfeil auf der Strasse und laeuft um Kurven herum, statt geradeaus zu
/// schiessen). Kommt die naechste Messung, wird weich nachgefuehrt statt
/// gesprungen.
class SmoothTracker {
  /// Wie lange hoechstens ueber die letzte Messung hinaus weitergerechnet
  /// wird (Tunnel, GPS-Aussetzer).
  static const double maxExtrapolateSec = 2.0;

  /// Ab dieser Abweichung wird gesprungen statt geglitten (m).
  static const double snapM = 60;

  RoutePoint? _fix;
  double _speed = 0;
  double? _fixHeading;
  double? _fixAlong;
  int _fixUs = 0;
  int _lastFrameUs = 0;

  /// Angezeigte Position und Fahrtrichtung (Grad).
  RoutePoint? pos;
  double heading = 0;
  double? _shownAlong;

  /// Angezeigte Position entlang der Route (m), falls auf der Route.
  double? get shownAlongM => _shownAlong;

  /// Neue GPS-Messung. [alongM]: Lage auf der Route, wenn der Fahrer auf
  /// ihr ist - sonst null.
  void onFix(RoutePoint p, double speedMs, double? headingDeg, int nowUs,
      {double? alongM}) {
    _fix = p;
    _speed = speedMs.isFinite ? math.max(0, speedMs) : 0;
    _fixHeading = headingDeg;
    _fixAlong = alongM;
    _fixUs = nowUs;
    if (alongM == null) _shownAlong = null;
    pos ??= p;
  }

  /// Ein Bild weiterrechnen.
  void frame(int nowUs, {List<RoutePoint>? route, List<double>? cum}) {
    final fix = _fix;
    if (fix == null) return;
    final dtFrame = _lastFrameUs == 0
        ? 0.03
        : ((nowUs - _lastFrameUs) / 1e6).clamp(0.0, 0.5).toDouble();
    _lastFrameUs = nowUs;
    final dtFix =
        ((nowUs - _fixUs) / 1e6).clamp(0.0, maxExtrapolateSec).toDouble();
    final kPos = 1 - math.exp(-dtFrame / 0.25);
    final kHead = 1 - math.exp(-dtFrame / 0.35);

    double targetHeading;
    final along = _fixAlong;
    if (route != null && cum != null && route.length >= 2 && along != null) {
      // Auf der Route: entlang der Linie weiterrechnen.
      final target = math.min(cum.last, along + _speed * dtFix);
      final shown = _shownAlong;
      if (shown == null || (target - shown).abs() > snapM) {
        _shownAlong = target;
      } else if (target > shown) {
        _shownAlong = shown + (target - shown) * kPos;
      }
      // Liegt die Messung knapp hinter der Anzeige (Tempo gesunken),
      // bleibt der Pfeil stehen, statt zurueckzuspringen.
      final a = _shownAlong!;
      pos = pointAlong(route, cum, a);
      final ahead = pointAlong(route, cum, math.min(cum.last, a + 25));
      targetHeading = dist(pos!, ahead) > 1
          ? bearingDeg(pos!, ahead)
          : (_fixHeading ?? heading);
    } else {
      // Ohne Route: in Fahrtrichtung weiterrechnen.
      _shownAlong = null;
      final h = _fixHeading;
      final target = (h != null && _speed > 1.5)
          ? destinationPoint(fix, h, _speed * dtFix)
          : fix;
      final cur = pos ?? target;
      if (dist(cur, target) > snapM) {
        pos = target;
      } else {
        pos = RoutePoint(cur.lat + (target.lat - cur.lat) * kPos,
            cur.lon + (target.lon - cur.lon) * kPos);
      }
      targetHeading = h ?? heading;
    }
    // Richtung weich drehen - nie ueber den langen Weg.
    heading = (heading + angleDiff(heading, targetHeading) * kHead) % 360;
    if (heading < 0) heading += 360;
  }

  /// Zoom passend zum Tempo: in der Stadt nah, auf der Autobahn weiter
  /// weg - damit man sieht, was kommt.
  static double zoomForSpeed(double speedMs) {
    final kmh = speedMs * 3.6;
    if (kmh < 30) return 17;
    if (kmh < 60) return 16.3;
    if (kmh < 100) return 15.6;
    return 15;
  }
}

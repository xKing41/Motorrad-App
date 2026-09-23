import 'dart:math' as math;

import '../models/route_plan.dart';
import 'geo.dart';
import 'routing_engine.dart';

// ---------------------------------------------------------------------------
//  ROUTEN ZUSAMMENSETZEN
//
//  Eine geplante Tour ist mehr als "irgendeine Route von A nach B": ihre
//  Kurven sind das Ergebnis der Planung. Wenn unterwegs etwas dazwischen
//  kommt (Sperrung, Stau, falsch abgebogen), wird deshalb nicht die ganze
//  Tour neu berechnet, sondern nur das betroffene Stueck ersetzt - der
//  Rest bleibt genau so kurvig wie geplant.
// ---------------------------------------------------------------------------

/// Index des ersten Routenpunkts, der bei [alongM] oder dahinter liegt.
int indexAtOrAfter(List<double> cum, double alongM) {
  var lo = 0, hi = cum.length - 1;
  if (alongM <= 0) return 0;
  if (alongM >= cum.last) return hi;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (cum[mid] < alongM) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Teilstueck einer Route von [fromM] bis [toM] - mit den passenden
/// Abbiegeanweisungen und anteiliger Fahrzeit.
EngineRoute sliceRoute(EngineRoute r, double fromM, double toM,
    {List<double>? cum}) {
  final c = cum ?? cumulativeDistances(r.points);
  final pts = subPath(r.points, c, fromM, toM);
  final a = fromM.clamp(0.0, c.last);
  final b = toM.clamp(a, c.last);
  // subPath beginnt mit einem eingefuegten Punkt bei [a]; danach folgen
  // die Originalpunkte ab [first].
  final first = indexAtOrAfter(c, a + 1e-6);
  final steps = <RouteStep>[
    for (final s in r.steps)
      if (s.pointIndex < r.points.length &&
          c[s.pointIndex] >= a &&
          (c[s.pointIndex] < b || b >= c.last))
        s.shifted(
            math.max(0, math.min(pts.length - 1, s.pointIndex + 1 - first)) -
                s.pointIndex),
  ];
  final total = c.last;
  final share = total > 0 ? (b - a) / total : 0.0;
  return EngineRoute(
    points: pts,
    distanceM: r.distanceM * share,
    durationSec: (r.durationSec * share).round(),
    steps: steps,
  );
}

/// Haengt Routenstuecke aneinander. Liegen Ende und Anfang zweier Stuecke
/// am selben Ort, wird der doppelte Punkt weggelassen.
EngineRoute joinRoutes(List<EngineRoute> parts) {
  final pts = <RoutePoint>[];
  final steps = <RouteStep>[];
  var distM = 0.0;
  var timeS = 0;
  for (final r in parts) {
    if (r.points.isEmpty) continue;
    var skip = 0;
    if (pts.isNotEmpty && dist(pts.last, r.points.first) < 1) skip = 1;
    final offset = pts.length - skip;
    pts.addAll(r.points.skip(skip));
    for (final s in r.steps) {
      // Die "Losfahren"-Anweisung eines angehaengten Stuecks ist mitten
      // in der Tour sinnlos.
      if (offset > 0 && s.type == ManeuverType.start) continue;
      // Ebenso "Ziel erreicht" am Ende eines Zwischenstuecks.
      if (!identical(r, parts.last) && ManeuverType.isDestination(s.type)) {
        continue;
      }
      steps.add(s.shifted(offset));
    }
    distM += r.distanceM;
    timeS += r.durationSec;
  }
  return EngineRoute(
      points: pts, distanceM: distM, durationSec: timeS, steps: steps);
}

/// Ersetzt das Stueck [fromM]..[toM] einer Route durch [detour].
EngineRoute replaceSection(
    EngineRoute base, double fromM, double toM, EngineRoute detour) {
  final cum = cumulativeDistances(base.points);
  return joinRoutes([
    if (fromM > 1) sliceRoute(base, 0, fromM, cum: cum),
    detour,
    if (toM < cum.last - 1) sliceRoute(base, toM, cum.last, cum: cum),
  ]);
}

EngineRoute engineRouteOf(RoutePlan p) => EngineRoute(
    points: p.points,
    distanceM: p.distanceM,
    durationSec: p.durationSec,
    steps: p.steps);

RoutePlan planWith(RoutePlan p, EngineRoute r, {List<String>? notes}) =>
    p.copyWith(
      points: r.points,
      distanceM: r.distanceM,
      durationSec: r.durationSec,
      steps: r.steps,
      notes: notes,
    );

/// Punkte einer Verkehrsmeldung, die die Engine meiden soll: hoechstens
/// alle 300 m einer, maximal [max].
List<RoutePoint> avoidPointsFor(TrafficIncident inc, {int max = 12}) {
  final pts = inc.points;
  if (pts.isEmpty) return const [];
  if (pts.length == 1) return [pts.first];
  final len = pathLength(pts);
  final n = math.max(2, math.min(max, (len / 300).ceil() + 1));
  final cum = cumulativeDistances(pts);
  return [for (var i = 0; i < n; i++) pointAlong(pts, cum, len * i / (n - 1))];
}

/// Ergebnis einer Umfahrung oder Rueckfuehrung.
class PatchResult {
  PatchResult(this.route, this.extraM, this.extraSec);
  final EngineRoute route;

  /// Mehr-Strecke und Mehr-Zeit gegenueber dem ersetzten Stueck.
  final double extraM;
  final int extraSec;
}

/// Berechnet Umfahrungen und Rueckfuehrungen fuer eine bestehende Route.
class RoutePatcher {
  RoutePatcher(this.engine, this.prefs);

  final RoutingEngine engine;
  final RoutingPrefs prefs;

  /// Umfaehrt eine Stelle der Route: ab [fromM] (oder ab der aktuellen
  /// Position [here]) bis [toM], ohne die Strassen an [avoid].
  Future<PatchResult> avoidSection(
    EngineRoute base, {
    required double fromM,
    required double toM,
    required List<RoutePoint> avoid,
    RoutePoint? here,
    double? heading,
  }) async {
    final cum = cumulativeDistances(base.points);
    final a = fromM.clamp(0.0, cum.last);
    final b = toM.clamp(a, cum.last);
    final start = here ?? pointAlong(base.points, cum, a);
    final end = pointAlong(base.points, cum, b);
    final detour = (await engine.route([
      Waypoint(start, WaypointKind.endpoint, heading: heading),
      Waypoint(end, WaypointKind.endpoint),
    ], prefs.withAvoid(avoid)))
        .first;
    final old = sliceRoute(base, a, b, cum: cum);
    final joined = replaceSection(base, a, b, detour);
    return PatchResult(joined, detour.distanceM - old.distanceM,
        detour.durationSec - old.durationSec);
  }

  // -------------------------------------------------------------------
  //  Bearbeiten auf der Karte (vor der Fahrt)
  //
  //  Wie beim Umfahren unterwegs wird nur ein Stueck um die Stelle neu
  //  berechnet - der Rest der Tour bleibt genau so kurvig wie geplant.
  // -------------------------------------------------------------------

  /// Laenge des Stuecks vor und hinter der Stelle, das neu berechnet
  /// wird (m).
  static const double editSpanM = 4000;

  (double, double, double) _span(EngineRoute base, RoutePoint p,
      List<double> cum) {
    final hit = projectOnPolyline(p, base.points, cum);
    final along = hit?.alongM ?? 0;
    return (
      along,
      math.max(0.0, along - editSpanM),
      math.min(cum.last, along + editSpanM),
    );
  }

  /// Die Tour soll ueber [p] fuehren.
  Future<PatchResult> via(EngineRoute base, RoutePoint p) async {
    final cum = cumulativeDistances(base.points);
    final (_, a, b) = _span(base, p, cum);
    final detour = (await engine.route([
      Waypoint(pointAlong(base.points, cum, a), WaypointKind.endpoint),
      Waypoint(p, WaypointKind.shape),
      Waypoint(pointAlong(base.points, cum, b), WaypointKind.endpoint),
    ], prefs))
        .first;
    final old = sliceRoute(base, a, b, cum: cum);
    return PatchResult(replaceSection(base, a, b, detour),
        detour.distanceM - old.distanceM, detour.durationSec - old.durationSec);
  }

  /// Die Strasse an [p] meiden (z. B. bekannte Baustelle, schlechter
  /// Belag).
  Future<PatchResult> avoidAt(EngineRoute base, RoutePoint p) {
    final cum = cumulativeDistances(base.points);
    final (along, a, b) = _span(base, p, cum);
    final avoid = [
      for (var d = -150.0; d <= 150; d += 75)
        pointAlong(base.points, cum, (along + d).clamp(0.0, cum.last)),
    ];
    return avoidSection(base, fromM: a, toM: b, avoid: avoid);
  }

  /// Stueck um [p] ohne Zwischenziel neu berechnen (Stopp entfernen).
  Future<PatchResult> without(EngineRoute base, RoutePoint p) async {
    final cum = cumulativeDistances(base.points);
    final (_, a, b) = _span(base, p, cum);
    final detour = (await engine.route([
      Waypoint(pointAlong(base.points, cum, a), WaypointKind.endpoint),
      Waypoint(pointAlong(base.points, cum, b), WaypointKind.endpoint),
    ], prefs))
        .first;
    final old = sliceRoute(base, a, b, cum: cum);
    return PatchResult(replaceSection(base, a, b, detour),
        detour.distanceM - old.distanceM, detour.durationSec - old.durationSec);
  }

  /// Fuehrt einen Fahrer, der die Route verlassen hat, auf sie zurueck.
  ///
  /// Ziel ist nicht der Punkt, an dem er abgebogen ist (dann hiesse es
  /// minutenlang "bitte wenden"), sondern die naechstgelegene Stelle der
  /// Route vor ihm - von dort geht es wie geplant weiter.
  Future<PatchResult> rejoin(
    EngineRoute base, {
    required RoutePoint here,
    required double lastAlongM,
    double? heading,
  }) async {
    final cum = cumulativeDistances(base.points);
    final target = rejoinTarget(base.points, cum, here, lastAlongM);
    final detour = (await engine.route([
      Waypoint(here, WaypointKind.endpoint, heading: heading),
      Waypoint(pointAlong(base.points, cum, target), WaypointKind.endpoint),
    ], prefs))
        .first;
    final rest = target < cum.last - 1
        ? sliceRoute(base, target, cum.last, cum: cum)
        : null;
    final joined = joinRoutes([detour, if (rest != null) rest]);
    final skipped = target - lastAlongM;
    return PatchResult(joined, detour.distanceM - skipped,
        detour.durationSec);
  }

  /// Wo die Rueckfuehrung auf die Route treffen soll (m ab Start):
  /// die Stelle vor dem Fahrer, die ihm am naechsten liegt, plus ein
  /// Stueck Vorlauf - so muss er nicht auf der Route wenden.
  static double rejoinTarget(List<RoutePoint> pts, List<double> cum,
      RoutePoint here, double lastAlongM) {
    final total = cum.last;
    if (total - lastAlongM < 2000) return total;
    final from = indexAtOrAfter(cum, lastAlongM + 300);
    final to = indexAtOrAfter(cum, lastAlongM + 25000);
    final hit = projectOnPolyline(here, pts, cum, from: from, to: to);
    final base = hit?.alongM ?? lastAlongM + 1000;
    return math.min(total, math.max(base, lastAlongM + 300) + 1000);
  }
}

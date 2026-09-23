import 'dart:math' as math;

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  UEBERGABE AN ANDERE NAVI-APPS
//
//  Jeder soll das Navi nutzen koennen, das er mag. Die Wege dorthin:
//   * Google Maps: Link mit bis zu 9 Zwischenpunkten. Damit Google nicht
//     einfach die schnellste Strecke nimmt, liegen die Zwischenpunkte AUF
//     der geplanten Tour (Stopps zuerst, dazu gleichmaessig verteilte
//     Formpunkte). Lange Touren werden in Abschnitte geteilt.
//   * Waze, Apple Karten: kennen per Link nur EIN Ziel - naechster Stopp
//     oder Ziel.
//   * Beliebige Navi-App (TomTom GO, Sygic, OsmAnd, HERE ...): "geo:"-Link,
//     Android fragt, womit geoeffnet wird.
//   * Die ganze Tour exakt: GPX-Datei (TomTom GO, Garmin, Kurviger,
//     Calimoto, OsmAnd, MyRoute-app ...) - siehe GpxService.
// ---------------------------------------------------------------------------

class NavLink {
  NavLink(this.label, this.uri, {this.detail});
  final String label;
  final Uri uri;
  final String? detail;
}

class ExternalNav {
  /// Google erlaubt in Links hoechstens 9 Zwischenpunkte.
  static const int googleMaxWaypoints = 9;

  static String _c(RoutePoint p) =>
      '${p.lat.toStringAsFixed(6)},${p.lon.toStringAsFixed(6)}';

  /// Google-Maps-Links fuer die Tour, bei langen Touren mehrere
  /// Abschnitte. [partKm]: ungefaehre Laenge eines Abschnitts - je kuerzer,
  /// desto dichter liegen die Formpunkte und desto genauer haelt sich
  /// Google an die Tour.
  static List<NavLink> googleMaps(RoutePlan plan,
      {double partKm = 180, double fromM = 0}) {
    final pts = plan.points;
    if (pts.length < 2) return const [];
    final cum = cumulativeDistances(pts);
    final total = cum.last;
    final start = math.min(fromM, total);

    final stops = <double>[
      for (final p in plan.pois.where((p) => p.source == 'stop'))
        if (projectOnPolyline(RoutePoint(p.lat, p.lon), pts, cum) case final h?)
          if (h.alongM > start + 500 && h.alongM < total - 500) h.alongM,
    ]..sort();
    final stopPts = {
      for (final p in plan.pois.where((p) => p.source == 'stop'))
        if (projectOnPolyline(RoutePoint(p.lat, p.lon), pts, cum) case final h?)
          h.alongM: RoutePoint(p.lat, p.lon),
    };

    final remain = total - start;
    final parts = math.max(
      1,
      math.max((remain / (partKm * 1000)).ceil(),
          (stops.length / (googleMaxWaypoints - 2)).ceil()),
    );

    final out = <NavLink>[];
    for (var i = 0; i < parts; i++) {
      final a = start + remain * i / parts;
      final b = start + remain * (i + 1) / parts;
      final inPart = stops.where((s) => s > a && s <= b).toList();
      final free = googleMaxWaypoints - inPart.length;
      // Formpunkte gleichmaessig, aber nicht direkt neben einem Stopp.
      final shape = <double>[];
      for (var k = 1; k <= free; k++) {
        final t = a + (b - a) * k / (free + 1);
        if (inPart.any((s) => (s - t).abs() < 3000)) continue;
        shape.add(t);
      }
      final via = [...inPart, ...shape]..sort();
      final wps = [
        for (final t in via.take(googleMaxWaypoints))
          stopPts[t] ?? pointAlong(pts, cum, t),
      ];
      final dest = pointAlong(pts, cum, b);
      final q = <String, String>{
        'api': '1',
        // Erster Abschnitt ohne Start: Google faengt beim Standort an.
        if (i > 0) 'origin': _c(pointAlong(pts, cum, a)),
        'destination': _c(dest),
        if (wps.isNotEmpty) 'waypoints': wps.map(_c).join('|'),
        'travelmode': 'driving',
      };
      out.add(NavLink(
        parts == 1 ? 'Google Maps' : 'Google Maps · Abschnitt ${i + 1}/$parts',
        Uri.https('www.google.com', '/maps/dir/', q),
        detail: '${((b - a) / 1000).round()} km, ${wps.length} Zwischenpunkte',
      ));
    }
    return out;
  }

  /// Naechstes Ziel fuer Apps, die nur ein Ziel kennen: der naechste
  /// Stopp nach [fromM], sonst das Ende der Tour.
  static (RoutePoint, String) nextTarget(RoutePlan plan, {double fromM = 0}) {
    final pts = plan.points;
    final cum = cumulativeDistances(pts);
    (Poi, double)? best;
    for (final p in plan.pois.where((p) => p.source == 'stop')) {
      final h = projectOnPolyline(RoutePoint(p.lat, p.lon), pts, cum);
      if (h == null || h.alongM <= fromM + 300) continue;
      if (best == null || h.alongM < best.$2) best = (p, h.alongM);
    }
    if (best != null) {
      return (RoutePoint(best.$1.lat, best.$1.lon), best.$1.displayName);
    }
    return (pts.last, plan.roundTrip ? 'Start/Ziel' : (plan.title ?? 'Ziel'));
  }

  static Uri waze(RoutePoint p) => Uri.https('waze.com', '/ul',
      {'ll': _c(p), 'navigate': 'yes'});

  static Uri appleMaps(RoutePoint p) =>
      Uri.https('maps.apple.com', '/', {'daddr': _c(p), 'dirflg': 'd'});

  /// Android: "Oeffnen mit ..." - jede installierte Navi-App.
  static Uri geo(RoutePoint p, String label) {
    final safe = label.replaceAll(RegExp(r'[()]'), '');
    return Uri.parse('geo:${_c(p)}?q=${_c(p)}(${Uri.encodeComponent(safe)})');
  }
}

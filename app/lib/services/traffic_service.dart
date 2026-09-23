import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';
import 'geo.dart';
import 'route_patch.dart';
import 'routing_engine.dart';

// ---------------------------------------------------------------------------
//  VERKEHRSLAGE
//
//  Staus, Sperrungen, Baustellen und Unfaelle kommen von der TomTom
//  Traffic API. Freie Kartendaten (OpenStreetMap) kennen nur dauerhafte
//  Sperrungen - aktuelle Verkehrslage gibt es nirgends kostenlos und ohne
//  Schluessel. TomTom hat ein kostenloses Kontingent (2.500 Abfragen am
//  Tag), das fuer einen Fahrer weit reicht; der Schluessel wird in den
//  Einstellungen eingetragen.
//
//  Die Route selbst berechnet weiterhin Valhalla - TomTom liefert nur die
//  Meldungen, die Umfahrung rechnet der Planer mit denselben Vorlieben
//  (kurvig, ohne Autobahn ...) wie die Tour selbst.
// ---------------------------------------------------------------------------

class TrafficService {
  TrafficService(this.apiKey, {http.Client? client, this.timeout = const Duration(seconds: 15)})
      : _client = client;

  final String apiKey;
  final Duration timeout;
  final http.Client? _client;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// Hoechste Flaeche je Abfrage bei TomTom: 10.000 km².
  static const double maxBoxKm2 = 9000;

  /// Meldungen in einem Rechteck.
  /// null = Abfrage fehlgeschlagen (Netz, Schluessel).
  Future<List<TrafficIncident>?> inBox(
      double minLat, double minLon, double maxLat, double maxLon) async {
    const fields = '{incidents{type,geometry{type,coordinates},'
        'properties{id,iconCategory,magnitudeOfDelay,events{description},'
        'from,to,length,delay,roadNumbers}}}';
    final uri = Uri.https('api.tomtom.com',
        '/traffic/services/5/incidentDetails', {
      'key': apiKey.trim(),
      'bbox': '${_f(minLon)},${_f(minLat)},${_f(maxLon)},${_f(maxLat)}',
      'fields': fields,
      'language': 'de-DE',
      'timeValidityFilter': 'present',
    });
    try {
      final c = _client;
      final res = await (c != null ? c.get(uri) : http.get(uri)).timeout(timeout);
      if (res.statusCode == 403 || res.statusCode == 401) {
        throw TrafficKeyException();
      }
      if (res.statusCode != 200) return null;
      return parse(jsonDecode(utf8.decode(res.bodyBytes)));
    } on TrafficKeyException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  static String _f(double v) => v.toStringAsFixed(5);

  /// Wertet die Antwort der Incident-Details-API aus.
  static List<TrafficIncident> parse(dynamic data) {
    if (data is! Map) return const [];
    final out = <TrafficIncident>[];
    for (final e in (data['incidents'] as List?) ?? const []) {
      if (e is! Map) continue;
      final props = (e['properties'] as Map?) ?? const {};
      final geom = (e['geometry'] as Map?) ?? const {};
      final pts = <RoutePoint>[];
      final coords = geom['coordinates'];
      if (geom['type'] == 'Point' && coords is List && coords.length >= 2) {
        pts.add(RoutePoint(
            (coords[1] as num).toDouble(), (coords[0] as num).toDouble()));
      } else if (coords is List) {
        for (final c in coords) {
          if (c is List && c.length >= 2) {
            pts.add(RoutePoint(
                (c[1] as num).toDouble(), (c[0] as num).toDouble()));
          }
        }
      }
      if (pts.isEmpty) continue;
      final events = (props['events'] as List?) ?? const [];
      final desc = events
          .whereType<Map>()
          .map((m) => m['description'])
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .join(', ');
      final roads = ((props['roadNumbers'] as List?) ?? const [])
          .whereType<String>()
          .join('/');
      out.add(TrafficIncident(
        id: '${props['id'] ?? out.length}',
        category: categoryOf((props['iconCategory'] as num?)?.toInt() ?? 0),
        points: pts,
        description: desc.isEmpty ? null : desc,
        road: roads.isEmpty ? null : roads,
        from: props['from'] as String?,
        to: props['to'] as String?,
        delaySec: (props['delay'] as num?)?.round() ?? 0,
        magnitude: (props['magnitudeOfDelay'] as num?)?.toInt() ?? 0,
        lengthM: (props['length'] as num?)?.toDouble() ?? pathLength(pts),
      ));
    }
    return out;
  }

  static TrafficCategory categoryOf(int icon) => switch (icon) {
        6 => TrafficCategory.jam,
        8 => TrafficCategory.closed,
        7 => TrafficCategory.laneClosed,
        9 => TrafficCategory.roadworks,
        1 => TrafficCategory.accident,
        3 || 14 => TrafficCategory.hazard,
        2 || 4 || 5 || 10 || 11 => TrafficCategory.weather,
        _ => TrafficCategory.other,
      };

  /// Meldungen entlang eines Routenabschnitts ([fromM] bis [toM]), mit
  /// ihrer Lage auf der Route. Nur, was wirklich AUF der Route liegt -
  /// eine Sperrung auf der Parallelstrasse interessiert nicht.
  ///
  /// null = keine Verbindung zum Dienst.
  Future<List<TrafficIncident>?> alongRoute(
    List<RoutePoint> pts, {
    double fromM = 0,
    double? toM,
    int maxBoxes = 25,
  }) async {
    if (pts.length < 2) return const [];
    final cum = cumulativeDistances(pts);
    final end = math.min(toM ?? cum.last, cum.last);
    final boxes = routeBoxes(pts, cum, fromM, end, maxBoxes: maxBoxes);
    final seen = <String>{};
    final raw = <TrafficIncident>[];
    var failed = 0;
    for (final b in boxes) {
      final list = await inBox(b.$1, b.$2, b.$3, b.$4);
      if (list == null) {
        failed++;
        continue;
      }
      for (final i in list) {
        if (seen.add(i.id)) raw.add(i);
      }
    }
    if (boxes.isNotEmpty && failed == boxes.length) return null;
    return matchToRoute(raw, pts, cum, fromM: fromM, toM: end);
  }

  /// Rechtecke entlang der Route, jedes unter der Flaechengrenze.
  static List<(double, double, double, double)> routeBoxes(
    List<RoutePoint> pts,
    List<double> cum,
    double fromM,
    double toM, {
    double stepM = 60000,
    double padDeg = 0.01,
    int maxBoxes = 25,
  }) {
    final out = <(double, double, double, double)>[];
    for (var a = fromM; a < toM && out.length < maxBoxes; a += stepM) {
      final part = subPath(pts, cum, a, math.min(toM, a + stepM));
      var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
      for (final p in part) {
        minLat = math.min(minLat, p.lat);
        maxLat = math.max(maxLat, p.lat);
        minLon = math.min(minLon, p.lon);
        maxLon = math.max(maxLon, p.lon);
      }
      out.add((minLat - padDeg, minLon - padDeg, maxLat + padDeg,
          maxLon + padDeg));
    }
    return out;
  }

  /// Welche Meldungen liegen auf der Route, und wo?
  ///
  /// Eine Meldung zaehlt, wenn ein grosser Teil ihrer Punkte dicht an der
  /// Route liegt (Staus haben einen Verlauf, der muss zur Route passen)
  /// - und in Fahrtrichtung: TomTom meldet Staus je Fahrtrichtung.
  static List<TrafficIncident> matchToRoute(
    List<TrafficIncident> raw,
    List<RoutePoint> pts,
    List<double> cum, {
    double fromM = 0,
    double? toM,
    double toleranceM = 35,
  }) {
    final end = toM ?? cum.last;
    final out = <TrafficIncident>[];
    for (final inc in raw) {
      final sample = inc.points.length <= 12
          ? inc.points
          : [
              for (var i = 0; i < 12; i++)
                inc.points[(i * (inc.points.length - 1) / 11).round()],
            ];
      final hits = <double>[];
      for (final p in sample) {
        final h = projectOnPolyline(p, pts, cum);
        if (h != null && h.distanceM <= toleranceM) hits.add(h.alongM);
      }
      if (hits.isEmpty || hits.length < (sample.length * 0.6).ceil()) {
        continue;
      }
      // Richtung: die Meldung muss entlang der Route "vorwaerts" laufen.
      if (sample.length >= 2 && hits.length >= 2 && hits.last < hits.first - 50) {
        continue;
      }
      final a = hits.reduce(math.min), b = hits.reduce(math.max);
      if (b < fromM || a > end) continue;
      out.add(inc.at(a, b));
    }
    out.sort((x, y) => x.alongM.compareTo(y.alongM));
    return out;
  }
}

class TrafficKeyException implements Exception {
  @override
  String toString() => 'TomTom-Schlüssel wurde nicht akzeptiert.';
}

/// Plant Umfahrungen um schwere Verkehrsmeldungen.
class TrafficRerouter {
  TrafficRerouter(this.patcher);
  final RoutePatcher patcher;

  /// Vorlauf vor und nach der Meldung, zwischen dem umgeplant wird.
  static const double leadM = 4000;
  static const double tailM = 3000;

  /// Umfaehrt [inc] auf [base]. Mit [here] ab der aktuellen Position
  /// (unterwegs), sonst ab einem Punkt kurz vor der Meldung.
  ///
  /// Rueckgabe null, wenn die Umfahrung nichts bringt: bei Staus nur,
  /// wenn sie schneller ist als im Stau zu stehen.
  Future<PatchResult?> detour(
    EngineRoute base,
    TrafficIncident inc, {
    RoutePoint? here,
    double? hereAlongM,
    double? heading,
  }) async {
    final from = hereAlongM != null
        ? math.max(hereAlongM, inc.alongM - leadM)
        : math.max(0.0, inc.alongM - leadM);
    final useHere = hereAlongM != null && inc.alongM - hereAlongM < leadM;
    final res = await patcher.avoidSection(
      base,
      fromM: useHere ? hereAlongM : from,
      toM: inc.endAlongM + tailM,
      avoid: avoidPointsFor(inc),
      here: useHere ? here : null,
      heading: useHere ? heading : null,
    );
    if (!inc.isClosure && res.extraSec >= inc.delaySec) return null;
    return res;
  }
}

/// Verkehrslage schon beim Planen beruecksichtigen.
class TrafficPlanCheck {
  /// Prueft die Route auf Meldungen, umfaehrt Sperrungen und schwere
  /// Staus (wenn die Umfahrung schneller ist) und haengt den Rest als
  /// Hinweis an.
  static Future<RoutePlan> apply(
    RoutePlan plan,
    TrafficService traffic,
    RoutePatcher patcher, {
    void Function(String)? say,
  }) async {
    say?.call('Verkehrslage wird geprüft ...');
    List<TrafficIncident>? list;
    try {
      list = await traffic.alongRoute(plan.points);
    } on TrafficKeyException catch (e) {
      return plan.copyWith(notes: [...plan.notes, 'Verkehrslage: $e']);
    }
    if (list == null) {
      return plan.copyWith(notes: [
        ...plan.notes,
        'Verkehrslage konnte nicht abgerufen werden.',
      ]);
    }
    var route = engineRouteOf(plan);
    final notes = <String>[...plan.notes];
    final avoided = <String>{};
    final severe = list.where((i) => i.isSevere).toList();
    // Von hinten nach vorn: so bleiben die Positionen der vorderen
    // Meldungen auf der Route gueltig.
    for (final inc in severe.reversed) {
      say?.call('${inc.category.label} wird umfahren ...');
      try {
        final res = await TrafficRerouter(patcher).detour(route, inc);
        if (res == null) continue;
        route = res.route;
        avoided.add(inc.id);
        final km = res.extraM / 1000;
        notes.add('${inc.label} umfahren '
            '(${km >= 0 ? '+' : ''}${km.toStringAsFixed(1).replaceAll('.', ',')} km).');
      } on RouteException {
        notes.add('${inc.label}: keine Umfahrung gefunden.');
      }
    }
    final cum = cumulativeDistances(route.points);
    final rest = TrafficService.matchToRoute(
        list.where((i) => !avoided.contains(i.id)).toList(),
        route.points,
        cum);
    for (final i in rest.where((i) => i.isSevere)) {
      notes.add('${i.label} bei km ${(i.alongM / 1000).round()} - '
          'Umfahrung wäre nicht schneller.');
    }
    return planWith(plan, route, notes: notes).copyWith(traffic: rest);
  }
}

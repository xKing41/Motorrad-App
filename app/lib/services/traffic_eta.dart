import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  ANKUNFTSZEIT MIT ECHTEM VERKEHR (TomTom Routing, mit Schluessel)
//
//  Die kostenlose Routing-Engine kennt nur die uebliche Fahrzeit. Mit
//  TomTom-Schluessel wird die EIGENE Tour (nicht eine andere, schnellere)
//  bei TomTom nachgerechnet: Die Linie geht als "supportingPoints" mit,
//  TomTom legt sie auf seine Strassen und rechnet die Fahrzeit mit der
//  aktuellen Verkehrslage (Staus, stockender Verkehr, Sperrungen) - so
//  wie Google Maps und TomTom GO ihre Ankunftszeit rechnen.
//
//  Verbrauch: eine Abfrage beim Planen, unterwegs hoechstens alle
//  5 Minuten (2.500 am Tag sind frei).
// ---------------------------------------------------------------------------

class TrafficEta {
  const TrafficEta({
    required this.travelSec,
    required this.delaySec,
    required this.lengthM,
    required this.at,
  });

  /// Fahrzeit mit Verkehr (s).
  final int travelSec;

  /// Davon Verzoegerung durch Verkehr (s).
  final int delaySec;
  final double lengthM;

  /// Wann gerechnet wurde.
  final DateTime at;
}

class TomTomEta {
  TomTomEta(this.apiKey, {http.Client? client}) : _client = client;

  final String apiKey;
  final http.Client? _client;

  /// Hoechstzahl Stuetzpunkte je Anfrage.
  static const int maxPoints = 2000;

  /// Stuetzpunkte: die Linie, gleichmaessig ausgeduennt (Abstand mind.
  /// 30 m, hoechstens [maxPoints]) - genug, damit TomTom exakt dieselben
  /// Strassen nimmt.
  static List<RoutePoint> supportingPoints(List<RoutePoint> pts) {
    if (pts.length < 2) return pts;
    final len = pathLength(pts);
    final step = math.max(30.0, len / (maxPoints - 1));
    return resample(pts, step);
  }

  /// Fahrzeit fuer die Route ab [fromM] (m ab Start) mit aktuellem
  /// Verkehr. null = nicht verfuegbar.
  Future<TrafficEta?> forRoute(List<RoutePoint> route,
      {double fromM = 0}) async {
    if (route.length < 2) return null;
    final cum = cumulativeDistances(route);
    if (cum.last - fromM < 500) return null;
    final part = subPath(route, cum, fromM, cum.last);
    final sp = supportingPoints(part);
    final a = sp.first, b = sp.last;
    String ll(RoutePoint p) =>
        '${p.lat.toStringAsFixed(6)},${p.lon.toStringAsFixed(6)}';
    final uri = Uri.parse(
        'https://api.tomtom.com/routing/1/calculateRoute/${ll(a)}:${ll(b)}/json'
        '?key=${Uri.encodeQueryComponent(apiKey)}'
        '&traffic=true&routeType=fastest&travelMode=car'
        '&computeTravelTimeFor=all&departAt=now&language=de-DE');
    final body = jsonEncode({
      'supportingPoints': [
        for (final p in sp) {'latitude': p.lat, 'longitude': p.lon},
      ],
    });
    try {
      final c = _client;
      const headers = {'Content-Type': 'application/json'};
      final res = await (c != null
              ? c.post(uri, headers: headers, body: body)
              : http.post(uri, headers: headers, body: body))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      return parse(jsonDecode(utf8.decode(res.bodyBytes)), DateTime.now());
    } catch (_) {
      return null;
    }
  }

  static TrafficEta? parse(Object? data, DateTime now) {
    if (data is! Map) return null;
    final routes = data['routes'];
    if (routes is! List || routes.isEmpty) return null;
    final s = (routes.first as Map)['summary'];
    if (s is! Map) return null;
    final tt = (s['travelTimeInSeconds'] as num?)?.toInt();
    if (tt == null) return null;
    return TrafficEta(
      travelSec: tt,
      delaySec: (s['trafficDelayInSeconds'] as num?)?.toInt() ?? 0,
      lengthM: (s['lengthInMeters'] as num?)?.toDouble() ?? 0,
      at: now,
    );
  }
}

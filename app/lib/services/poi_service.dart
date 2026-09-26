import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/ride.dart';
import '../models/route_plan.dart';
import 'geo.dart';

/// Sucht echte Orte (Tankstellen, Aussichtspunkte, Rastplaetze ...) in
/// OpenStreetMap ueber die Overpass-API.
///
/// GRUNDREGEL FUER DIE KI-ANBINDUNG:
/// Koordinaten kommen ausschliesslich von hier oder vom Nutzer.
/// Ein Sprachmodell darf auswaehlen und beschreiben, aber niemals
/// Orte erfinden - eine erfundene Tankstelle ist auf dem Motorrad
/// ein echtes Problem, kein Schoenheitsfehler.
class PoiService {
  /// Oeffentliche Overpass-Server. Der erste ist der Hauptserver; ist er
  /// ueberlastet (passiert oefter), wird der naechste gefragt.
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  /// Sucht Orte im Umkreis eines Punktes, nach Entfernung sortiert.
  /// Liefert bei Netzproblemen eine leere Liste.
  static Future<List<Poi>> search({
    required double lat,
    required double lon,
    required List<PoiKind> kinds,
    double radiusM = 15000,
    int limitPerKind = 25,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (kinds.isEmpty) return [];
    final area = '(around:${radiusM.round()},${_f(lat)},${_f(lon)})';
    final list = await _query(kinds, area, limitPerKind, timeout) ?? [];
    list.sort((a, b) => distanceMeters(lat, lon, a.lat, a.lon)
        .compareTo(distanceMeters(lat, lon, b.lat, b.lon)));
    return list;
  }

  /// Sucht Orte in einem Streifen entlang einer Route - mit EINER
  /// Anfrage fuer alle Arten, statt einer je Stopp.
  ///
  /// Rueckgabe null = Suche fehlgeschlagen (Netz, Server ueberlastet),
  /// leere Liste = wirklich nichts gefunden.
  static Future<List<Poi>?> searchAlongRoute({
    required List<RoutePoint> route,
    required List<PoiKind> kinds,
    double corridorM = 1500,
    int limitPerKind = 80,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (kinds.isEmpty || route.length < 2) return [];
    return _query(kinds, corridor(route, corridorM), limitPerKind, timeout);
  }

  /// Overpass-Suchgebiet: Streifen um die Route. Die Linie wird auf
  /// hoechstens etwa 120 Punkte ausgeduennt - das reicht fuer einen
  /// Suchstreifen von gut einem Kilometer voellig aus.
  static String corridor(List<RoutePoint> route, double corridorM) {
    final len = pathLength(route);
    final simple = resample(route, math.max(300.0, len / 120));
    final coords = simple.map((p) => '${_f(p.lat)},${_f(p.lon)}').join(',');
    return '(around:${corridorM.round()},$coords)';
  }

  static String _f(double v) => v.toStringAsFixed(5);

  /// Overpass-Abfrage mit eigenem Ergebnis-Limit JE ART. Vorher galt das
  /// Limit fuer alle Arten zusammen - dann kamen z. B. zwoelf Restaurants
  /// und keine einzige Tankstelle zurueck.
  static String buildQuery(List<PoiKind> kinds, String area, int limitPerKind) {
    final b = StringBuffer('[out:json][timeout:25];');
    for (final k in kinds) {
      b.write('(');
      for (final f in k.osmFilters) {
        b.write('nwr$f$area;');
      }
      b.write(');out center $limitPerKind;');
    }
    return b.toString();
  }

  static Future<List<Poi>?> _query(
    List<PoiKind> kinds,
    String area,
    int limitPerKind,
    Duration timeout,
  ) async {
    final data = await overpass(buildQuery(kinds, area, limitPerKind),
        timeout: timeout);
    return data == null ? null : parseElements(data, kinds);
  }

  /// Fuehrt eine Overpass-Abfrage aus; probiert bei Ueberlastung den
  /// naechsten Server. null = fehlgeschlagen.
  static Future<Map<String, dynamic>?> overpass(String query,
      {Duration timeout = const Duration(seconds: 30)}) async {
    for (final endpoint in _endpoints) {
      try {
        final res = await http
            .post(
              Uri.parse(endpoint),
              body: {'data': query},
              headers: {'User-Agent': 'Schraeglage/4.26 (Motorrad-App)'},
            )
            .timeout(timeout);
        if (res.statusCode != 200) continue;
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        // Overpass meldet eine Zeitueberschreitung NICHT als Fehler,
        // sondern mit Code 200, halben Daten und einem Hinweis "remark".
        // Das sah vorher aus wie "nichts gefunden".
        final remark = data is Map ? '${data['remark'] ?? ''}' : '';
        if (remark.contains('timed out') || remark.contains('runtime error')) {
          continue;
        }
        if (data is Map<String, dynamic>) return data;
      } catch (_) {
        // naechsten Server probieren
      }
    }
    return null;
  }

  /// Wertet die Overpass-Antwort aus. Doppelt eingetragene Orte (etwa
  /// eine Tankstelle als Punkt UND als Flaeche) werden zusammengefasst.
  static List<Poi> parseElements(dynamic data, List<PoiKind> kinds) {
    if (data is! Map) return [];
    final elements = (data['elements'] as List?) ?? const [];
    final out = <Poi>[];
    for (final e in elements.whereType<Map<String, dynamic>>()) {
      final tags = (e['tags'] as Map?)?.cast<String, dynamic>() ?? {};
      final center = e['center'] is Map ? e['center'] as Map : const {};
      final plat = (e['lat'] as num?)?.toDouble() ??
          (center['lat'] as num?)?.toDouble();
      final plon = (e['lon'] as num?)?.toDouble() ??
          (center['lon'] as num?)?.toDouble();
      if (plat == null || plon == null) continue;

      final kind = kindFromTags(tags);
      if (kind == null || !kinds.contains(kind)) continue;

      final dup = out.any((p) =>
          p.kind == kind && distanceMeters(p.lat, p.lon, plat, plon) < 40);
      if (dup) continue;

      out.add(Poi(
        id: 'osm_${e['type'] ?? 'node'}_${e['id']}',
        kind: kind,
        lat: plat,
        lon: plon,
        name: tags['name'] as String?,
        detail: detailFromTags(tags),
      ));
    }
    return out;
  }

  static PoiKind? kindFromTags(Map<String, dynamic> t) {
    if (t['amenity'] == 'fuel') return PoiKind.fuel;
    if (t['tourism'] == 'viewpoint' || t['natural'] == 'peak') {
      return PoiKind.viewpoint;
    }
    if (t['amenity'] == 'cafe' ||
        t['amenity'] == 'restaurant' ||
        t['amenity'] == 'biergarten') {
      return PoiKind.food;
    }
    if (t['highway'] == 'rest_area' ||
        t['tourism'] == 'picnic_site' ||
        t['leisure'] == 'picnic_table') {
      return PoiKind.rest;
    }
    if (t['amenity'] == 'drinking_water') return PoiKind.water;
    if (t['shop'] == 'motorcycle') return PoiKind.workshop;
    return null;
  }

  static String? detailFromTags(Map<String, dynamic> t) {
    String? s(String k) {
      final v = t[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    if (t['amenity'] == 'fuel') return s('brand') ?? s('operator');
    if (t['tourism'] == 'viewpoint') return 'Aussichtspunkt';
    if (t['natural'] == 'peak') {
      final ele = s('ele');
      return ele != null ? 'Gipfel, $ele m' : 'Gipfel';
    }
    switch (t['amenity']) {
      case 'cafe':
        return 'Café';
      case 'restaurant':
        return 'Restaurant';
      case 'biergarten':
        return 'Biergarten';
    }
    if (t['highway'] == 'rest_area') return 'Rastplatz';
    if (t['tourism'] == 'picnic_site') return 'Picknickplatz';
    if (t['leisure'] == 'picnic_table') return 'Picknicktisch';
    return null;
  }

  /// Wie gut eignet sich ein Ort als geplanter Stopp? Hoeher = besser.
  /// Ein benannter Aussichtspunkt schlaegt einen Gipfel im Wald, ein
  /// Rastplatz einen einzelnen Picknicktisch.
  static double stopQuality(Poi p) {
    var q = 1.0;
    if (p.name != null && p.name!.isNotEmpty) q += 0.3;
    final d = p.detail ?? '';
    // Ein Gipfel ist oft nur ein Punkt im Wald ohne jede Aussicht.
    if (d.startsWith('Gipfel')) q -= 0.8;
    if (d == 'Picknicktisch') q -= 0.4;
    if (d == 'Rastplatz') q += 0.2;
    return q;
  }
}

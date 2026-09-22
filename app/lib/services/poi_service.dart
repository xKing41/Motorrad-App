import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ride.dart';
import '../models/route_plan.dart';

/// Sucht echte Orte (Tankstellen, Aussichtspunkte, Rastplaetze ...) in
/// OpenStreetMap ueber die Overpass-API.
///
/// GRUNDREGEL FUER DIE SPAETERE KI-ANBINDUNG:
/// Koordinaten kommen ausschliesslich von hier oder vom Nutzer.
/// Ein Sprachmodell darf auswaehlen und beschreiben, aber niemals
/// Orte erfinden - eine erfundene Tankstelle ist auf dem Motorrad
/// ein echtes Problem, kein Schoenheitsfehler.
class PoiService {
  static const _endpoint = 'https://overpass-api.de/api/interpreter';

  /// Sucht POIs im Umkreis eines Punktes.
  static Future<List<Poi>> search({
    required double lat,
    required double lon,
    required List<PoiKind> kinds,
    double radiusM = 15000,
    int limitPerKind = 25,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (kinds.isEmpty) return [];

    final parts = <String>[];
    for (final k in kinds) {
      for (final f in k.osmFilters) {
        parts.add('$f(around:${radiusM.round()},$lat,$lon);');
      }
    }
    final query = '[out:json][timeout:25];(${parts.join()});out center $limitPerKind;';

    try {
      final res = await http
          .post(
            Uri.parse(_endpoint),
            body: {'data': query},
            headers: {'User-Agent': 'Schraeglage/3.0 (Motorrad-App)'},
          )
          .timeout(timeout);

      if (res.statusCode != 200) return [];
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final elements = (data['elements'] as List?) ?? const [];

      final out = <Poi>[];
      for (final e in elements.whereType<Map<String, dynamic>>()) {
        final tags = (e['tags'] as Map?)?.cast<String, dynamic>() ?? {};
        final plat = (e['lat'] as num?)?.toDouble() ??
            (e['center']?['lat'] as num?)?.toDouble();
        final plon = (e['lon'] as num?)?.toDouble() ??
            (e['center']?['lon'] as num?)?.toDouble();
        if (plat == null || plon == null) continue;

        final kind = _kindFromTags(tags);
        if (kind == null || !kinds.contains(kind)) continue;

        out.add(Poi(
          id: 'osm_${e['type'] ?? 'node'}_${e['id']}',
          kind: kind,
          lat: plat,
          lon: plon,
          name: tags['name'] as String?,
        ));
      }

      // Nach Entfernung sortieren, damit die naechstgelegenen zuerst kommen
      out.sort((a, b) => distanceMeters(lat, lon, a.lat, a.lon)
          .compareTo(distanceMeters(lat, lon, b.lat, b.lon)));
      return out;
    } catch (_) {
      return [];
    }
  }

  static PoiKind? _kindFromTags(Map<String, dynamic> t) {
    if (t['amenity'] == 'fuel') return PoiKind.fuel;
    if (t['tourism'] == 'viewpoint' || t['natural'] == 'peak') {
      return PoiKind.viewpoint;
    }
    if (t['amenity'] == 'cafe' || t['amenity'] == 'restaurant') {
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

  /// Sucht den passendsten POI einer Art nahe eines Punktes der Route.
  /// Wird gebraucht, um aus einem [StopWish] ("Tankstelle nach 90 km")
  /// einen echten Ort zu machen.
  static Future<Poi?> nearest({
    required double lat,
    required double lon,
    required PoiKind kind,
    double radiusM = 8000,
  }) async {
    final list = await search(
      lat: lat,
      lon: lon,
      kinds: [kind],
      radiusM: radiusM,
      limitPerKind: 10,
    );
    return list.isEmpty ? null : list.first;
  }
}

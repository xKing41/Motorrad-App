import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Ein gefundener Ort.
class Place {
  const Place({
    required this.name,
    required this.lat,
    required this.lon,
    this.detail = '',
  });

  final String name;

  /// Zusatz fuer die Anzeige ("58300 Wetter, Nordrhein-Westfalen").
  final String detail;
  final double lat;
  final double lon;

  String get fullName => detail.isEmpty ? name : '$name, $detail';
}

/// Ortssuche ueber OpenStreetMap-Daten.
///
/// Zuerst Photon (komoot), bei Fehlern Nominatim. Beide ohne Schluessel.
/// Gesucht wird nur auf Knopfdruck, nie bei jedem Tastendruck - die
/// Dienste sind kostenlos und sollen es bleiben.
class Geocoder {
  static const _ua = {'User-Agent': 'Schraeglage/4.22 (Motorrad-App)'};

  static Future<List<Place>> search(
    String query, {
    double? nearLat,
    double? nearLon,
    int limit = 6,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final r = await _photon(q, nearLat, nearLon, limit);
      if (r.isNotEmpty) return r;
    } catch (_) {
      // Weiter mit Nominatim.
    }
    try {
      return await _nominatim(q, limit);
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Place>> _photon(
      String q, double? lat, double? lon, int limit) async {
    final params = <String, String>{
      'q': q,
      'lang': 'de',
      'limit': '$limit',
      if (lat != null && lon != null) 'lat': lat.toStringAsFixed(4),
      if (lat != null && lon != null) 'lon': lon.toStringAsFixed(4),
    };
    final uri = Uri.https('photon.komoot.io', '/api/', params);
    final res =
        await http.get(uri, headers: _ua).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    return parsePhoton(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  /// Wertet eine Photon-Antwort (GeoJSON) aus.
  static List<Place> parsePhoton(dynamic data) {
    if (data is! Map) return const [];
    final out = <Place>[];
    for (final f in (data['features'] as List?) ?? const []) {
      if (f is! Map) continue;
      final coords = (f['geometry'] as Map?)?['coordinates'];
      final p = f['properties'];
      if (coords is! List || coords.length < 2 || p is! Map) continue;
      String? s(String k) {
        final v = p[k];
        return (v is String && v.trim().isNotEmpty) ? v.trim() : null;
      }

      final street = s('street');
      final hn = s('housenumber');
      final name = s('name') ??
          (street != null ? (hn != null ? '$street $hn' : street) : null) ??
          s('city');
      if (name == null) continue;
      final city = s('city') ?? s('town') ?? s('village') ?? s('county');
      final plzOrt = [s('postcode'), if (city != name) city]
          .whereType<String>()
          .join(' ');
      final detail = [
        if (plzOrt.isNotEmpty) plzOrt,
        if (s('state') != null) s('state')!,
        if (s('country') != null && s('country') != 'Deutschland')
          s('country')!,
      ].join(', ');
      out.add(Place(
        name: name,
        detail: detail,
        lat: (coords[1] as num).toDouble(),
        lon: (coords[0] as num).toDouble(),
      ));
    }
    return out;
  }

  static Future<List<Place>> _nominatim(String q, int limit) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': q,
      'format': 'jsonv2',
      'limit': '$limit',
      'accept-language': 'de',
    });
    final res =
        await http.get(uri, headers: _ua).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! List) return const [];
    final out = <Place>[];
    for (final e in data) {
      if (e is! Map) continue;
      final lat = double.tryParse('${e['lat']}');
      final lon = double.tryParse('${e['lon']}');
      final display = (e['display_name'] ?? '').toString();
      if (lat == null || lon == null || display.isEmpty) continue;
      final parts = display.split(', ');
      final name = (e['name'] is String && (e['name'] as String).isNotEmpty)
          ? e['name'] as String
          : parts.first;
      out.add(Place(
        name: name,
        detail: parts.skip(1).take(3).join(', '),
        lat: lat,
        lon: lon,
      ));
    }
    return out;
  }
}

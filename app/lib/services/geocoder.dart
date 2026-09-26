import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ride.dart' show distanceMeters;
import '../models/route_plan.dart';
import 'geo.dart';
import 'poi_service.dart';

/// Ein gefundener Ort.
class Place {
  const Place({
    required this.name,
    required this.lat,
    required this.lon,
    this.detail = '',
    this.kind = '',
  });

  final String name;

  /// Zusatz fuer die Anzeige ("58300 Wetter, Nordrhein-Westfalen").
  final String detail;

  /// Art des Orts ("Stadt", "Tankstelle", "Adresse" ...), falls bekannt.
  final String kind;
  final double lat;
  final double lon;

  String get fullName => detail.isEmpty ? name : '$name, $detail';

  RoutePoint get point => RoutePoint(lat, lon);
}

/// Ortssuche ueber OpenStreetMap-Daten - moeglichst ALLES finden:
///
///  * Orte, Ortsteile, Strassen, Hausnummern, Berge, Paesse, Seen,
///    Sehenswuerdigkeiten, Geschaefte, Gasthoefe ...: Photon (komoot) und
///    Nominatim GLEICHZEITIG, Ergebnisse zusammengefuehrt (jeder Dienst
///    findet Dinge, die der andere nicht findet).
///  * Koordinaten in jeder ueblichen Schreibweise ("51.45, 7.12",
///    "51°27'12\"N 7°7'E", Google-Maps- und geo:-Links).
///  * Kategorien in der Naehe: "Tankstelle", "Cafe", "Aussichtspunkt",
///    "Rastplatz", "Werkstatt", "Motorradtreff" ...
///  * Punkt auf der Karte ([reverse]).
///
/// Suchvorschlaege beim Tippen nur ueber Photon (dafuer gedacht);
/// Nominatim erst beim Absenden - dessen Regeln verbieten Suche bei jedem
/// Tastendruck.
class Geocoder {
  static const _ua = {'User-Agent': 'Schraeglage/4.28 (Motorrad-App)'};

  /// Vollstaendige Suche (Knopf "Suchen").
  static Future<List<Place>> search(
    String query, {
    double? nearLat,
    double? nearLon,
    int limit = 12,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    // 1. Koordinaten oder Kartenlink?
    final c = parseCoordinates(q);
    if (c != null) {
      final named = await reverse(c.lat, c.lon);
      return [
        Place(
          name: named?.name ?? 'Punkt ${_fmt(c.lat)}, ${_fmt(c.lon)}',
          detail: named?.detail ?? 'Koordinaten',
          kind: 'Koordinaten',
          lat: c.lat,
          lon: c.lon,
        ),
      ];
    }

    // 2. Kategorie in der Naehe ("Tankstelle", "Cafe" ...)?
    final cat = categoryOf(q);
    final futures = <Future<List<Place>>>[
      _safe(() => _photon(q, nearLat, nearLon, limit)),
      _safe(() => _nominatim(q, limit, nearLat, nearLon)),
      if (cat != null && nearLat != null && nearLon != null)
        _safe(() => _nearby(cat, nearLat, nearLon)),
    ];
    final res = await Future.wait(futures);
    final nearby = res.length > 2 ? res[2] : const <Place>[];
    return merge([nearby, res[0], res[1]], limit: limit + nearby.length);
  }

  /// Schnelle Vorschlaege beim Tippen (nur Photon).
  static Future<List<Place>> suggest(String query,
      {double? nearLat, double? nearLon}) async {
    final q = query.trim();
    if (q.length < 3 || parseCoordinates(q) != null) return const [];
    return _safe(() => _photon(q, nearLat, nearLon, 6));
  }

  static Future<List<Place>> _safe(Future<List<Place>> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return const [];
    }
  }

  static String _fmt(double v) => v.toStringAsFixed(5);

  // -------------------------------------------------------------------
  //  Zusammenfuehren
  // -------------------------------------------------------------------

  /// Fuehrt Ergebnislisten zusammen (Reihenfolge der Listen = Vorrang).
  /// Doppelte (gleicher Name, naeher als 300 m, oder fast derselbe Punkt)
  /// erscheinen einmal.
  static List<Place> merge(List<List<Place>> lists, {int limit = 12}) {
    final out = <Place>[];
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9äöüß]'), '');
    for (final l in lists) {
      for (final p in l) {
        final dup = out.any((o) {
          final d = dist(o.point, p.point);
          return d < 25 || (d < 300 && norm(o.name) == norm(p.name));
        });
        if (!dup) out.add(p);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  // -------------------------------------------------------------------
  //  Koordinaten
  // -------------------------------------------------------------------

  /// Liest Koordinaten: "51.4567, 7.1234", "51,4567 7,1234",
  /// "N 51° 27.4' E 7° 7.2'", "51°27'24\"N 7°7'12\"E",
  /// Google-Maps-Links (…/@51.45,7.12,15z oder ?q=51.45,7.12) und
  /// "geo:51.45,7.12". null = keine Koordinaten.
  static ({double lat, double lon})? parseCoordinates(String s) {
    final t = s.trim();
    ({double lat, double lon})? ok(double la, double lo) =>
        la.abs() <= 90 && lo.abs() <= 180 && !(la == 0 && lo == 0)
            ? (lat: la, lon: lo)
            : null;

    // Links
    final at = RegExp(r'@(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)').firstMatch(t);
    if (at != null) {
      return ok(double.parse(at[1]!), double.parse(at[2]!));
    }
    final q = RegExp(r'(?:[?&](?:q|query|ll|daddr)=|geo:)(-?\d{1,2}\.\d+),\s*(-?\d{1,3}\.\d+)')
        .firstMatch(t);
    if (q != null) return ok(double.parse(q[1]!), double.parse(q[2]!));

    // Grad, Minuten, Sekunden mit Himmelsrichtung
    final dms = RegExp(
            r'''([NS])?\s*(\d{1,2})\s*°\s*(?:(\d{1,2}(?:[.,]\d+)?)\s*['′]\s*)?(?:(\d{1,2}(?:[.,]\d+)?)\s*(?:"|″|'')\s*)?([NS])?[\s,;]+([EOW])?\s*(\d{1,3})\s*°\s*(?:(\d{1,2}(?:[.,]\d+)?)\s*['′]\s*)?(?:(\d{1,2}(?:[.,]\d+)?)\s*(?:"|″|'')\s*)?([EOW])?''',
            caseSensitive: false)
        .firstMatch(t);
    if (dms != null) {
      double part(String? v) => v == null ? 0 : double.parse(v.replaceAll(',', '.'));
      var la = part(dms[2]) + part(dms[3]) / 60 + part(dms[4]) / 3600;
      var lo = part(dms[7]) + part(dms[8]) / 60 + part(dms[9]) / 3600;
      final ns = (dms[1] ?? dms[5] ?? 'N').toUpperCase();
      final ew = (dms[6] ?? dms[10] ?? 'E').toUpperCase();
      if (ns == 'S') la = -la;
      if (ew == 'W') lo = -lo;
      return ok(la, lo);
    }

    // Dezimal: "51.45, 7.12" oder deutsch "51,45 7,12" / "51,45; 7,12"
    final dec = RegExp(r'^(-?\d{1,2}\.\d+)\s*[,;\s]\s*(-?\d{1,3}\.\d+)$').firstMatch(t);
    if (dec != null) return ok(double.parse(dec[1]!), double.parse(dec[2]!));
    final decDe =
        RegExp(r'^(-?\d{1,2},\d+)\s*[;\s]\s*(-?\d{1,3},\d+)$').firstMatch(t);
    if (decDe != null) {
      return ok(double.parse(decDe[1]!.replaceAll(',', '.')),
          double.parse(decDe[2]!.replaceAll(',', '.')));
    }
    return null;
  }

  // -------------------------------------------------------------------
  //  Kategorien in der Naehe
  // -------------------------------------------------------------------

  static const Map<String, PoiKind> _categories = {
    'tankstelle': PoiKind.fuel,
    'tanke': PoiKind.fuel,
    'tanken': PoiKind.fuel,
    'sprit': PoiKind.fuel,
    'benzin': PoiKind.fuel,
    'cafe': PoiKind.food,
    'café': PoiKind.food,
    'kaffee': PoiKind.food,
    'restaurant': PoiKind.food,
    'essen': PoiKind.food,
    'imbiss': PoiKind.food,
    'biergarten': PoiKind.food,
    'gasthof': PoiKind.food,
    'einkehr': PoiKind.food,
    'motorradtreff': PoiKind.food,
    'bikertreff': PoiKind.food,
    'aussicht': PoiKind.viewpoint,
    'aussichtspunkt': PoiKind.viewpoint,
    'fotostopp': PoiKind.viewpoint,
    'gipfel': PoiKind.viewpoint,
    'rastplatz': PoiKind.rest,
    'parkplatz': PoiKind.rest,
    'pause': PoiKind.rest,
    'picknick': PoiKind.rest,
    'wasser': PoiKind.water,
    'trinkwasser': PoiKind.water,
    'werkstatt': PoiKind.workshop,
    'motorradwerkstatt': PoiKind.workshop,
    'motorradhändler': PoiKind.workshop,
    'motorradladen': PoiKind.workshop,
  };

  /// Ist die Suche eine Kategorie ("Tankstelle", "nächste Tanke",
  /// "Cafe in der Nähe")?
  static PoiKind? categoryOf(String q) {
    final words = q
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-zäöüßé ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    const filler = {
      'nächste', 'naechste', 'nächster', 'in', 'der', 'die', 'das', 'nähe',
      'naehe', 'hier', 'bei', 'mir', 'eine', 'ein', 'suche', 'zur', 'zum',
    };
    final rest = words.where((w) => !filler.contains(w)).toList();
    if (rest.length != 1) return null;
    final w = rest.single;
    return _categories[w] ?? _categories[w.endsWith('n') ? w.substring(0, w.length - 1) : w];
  }

  static Future<List<Place>> _nearby(PoiKind k, double lat, double lon) async {
    final pois = await PoiService.search(
        lat: lat, lon: lon, kinds: [k], radiusM: 20000, limitPerKind: 20);
    return [
      for (final p in pois.take(8))
        Place(
          name: p.displayName,
          detail: [
            '${(distanceMeters(lat, lon, p.lat, p.lon) / 1000).toStringAsFixed(1).replaceAll('.', ',')} km entfernt',
            if (p.detail != null && p.detail != p.displayName) p.detail!,
          ].join(' · '),
          kind: k.label,
          lat: p.lat,
          lon: p.lon,
        ),
    ];
  }

  // -------------------------------------------------------------------
  //  Photon
  // -------------------------------------------------------------------

  static Future<List<Place>> _photon(
      String q, double? lat, double? lon, int limit) async {
    final params = <String, String>{
      'q': q,
      'lang': 'de',
      'limit': '$limit',
      if (lat != null && lon != null) 'lat': lat.toStringAsFixed(4),
      if (lat != null && lon != null) 'lon': lon.toStringAsFixed(4),
      // Naehe zaehlt, aber nicht absolut: "Stilfser Joch" soll auch aus
      // Dortmund gefunden werden.
      if (lat != null) 'location_bias_scale': '0.3',
    };
    final uri = Uri.https('photon.komoot.io', '/api/', params);
    final res =
        await http.get(uri, headers: _ua).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    return parsePhoton(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  /// Uebersetzt die OSM-Art in Klartext.
  static String kindOf(String? key, String? value) {
    const v = {
      'city': 'Stadt',
      'town': 'Stadt',
      'village': 'Dorf',
      'hamlet': 'Weiler',
      'suburb': 'Ortsteil',
      'neighbourhood': 'Ortsteil',
      'locality': 'Ort',
      'isolated_dwelling': 'Einzelhaus',
      'fuel': 'Tankstelle',
      'restaurant': 'Restaurant',
      'cafe': 'Café',
      'biergarten': 'Biergarten',
      'pub': 'Kneipe',
      'fast_food': 'Imbiss',
      'hotel': 'Hotel',
      'guest_house': 'Pension',
      'camp_site': 'Campingplatz',
      'viewpoint': 'Aussichtspunkt',
      'peak': 'Gipfel',
      'saddle': 'Pass / Sattel',
      'mountain_pass': 'Pass',
      'lake': 'See',
      'water': 'Gewässer',
      'reservoir': 'Stausee',
      'castle': 'Burg / Schloss',
      'museum': 'Museum',
      'attraction': 'Sehenswürdigkeit',
      'parking': 'Parkplatz',
      'motorcycle_parking': 'Motorradparkplatz',
      'motorcycle': 'Motorradhändler',
      'car_repair': 'Werkstatt',
      'rest_area': 'Rastplatz',
      'services': 'Raststätte',
      'supermarket': 'Supermarkt',
      'house': 'Adresse',
    };
    if (value != null && v.containsKey(value)) return v[value]!;
    return switch (key) {
      'highway' => 'Straße',
      'place' => 'Ort',
      'building' => 'Gebäude',
      'amenity' => 'Einrichtung',
      'shop' => 'Geschäft',
      'tourism' => 'Tourismus',
      'natural' => 'Natur',
      'leisure' => 'Freizeit',
      'boundary' => 'Gebiet',
      _ => '',
    };
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
      final address = street != null ? (hn != null ? '$street $hn' : street) : null;
      final name = s('name') ?? address ?? s('city');
      if (name == null) continue;
      final city = s('city') ?? s('town') ?? s('village') ?? s('county');
      final plzOrt = [s('postcode'), if (city != name) city]
          .whereType<String>()
          .join(' ');
      final detail = [
        // Adresse eines benannten Orts (Gasthof "Zur Post", Hauptstr. 3).
        if (s('name') != null && address != null) address,
        if (plzOrt.isNotEmpty) plzOrt,
        if (s('state') != null) s('state')!,
        if (s('country') != null && s('country') != 'Deutschland')
          s('country')!,
      ].join(', ');
      final kind = hn != null && s('name') == null
          ? 'Adresse'
          : kindOf(s('osm_key'), s('osm_value'));
      out.add(Place(
        name: name,
        detail: detail,
        kind: kind,
        lat: (coords[1] as num).toDouble(),
        lon: (coords[0] as num).toDouble(),
      ));
    }
    return out;
  }

  // -------------------------------------------------------------------
  //  Nominatim
  // -------------------------------------------------------------------

  static Future<List<Place>> _nominatim(
      String q, int limit, double? lat, double? lon) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': q,
      'format': 'jsonv2',
      'limit': '$limit',
      'accept-language': 'de',
      'addressdetails': '0',
      // Sucht zuerst im Umkreis (rund 150 km), ohne andere auszuschliessen.
      if (lat != null && lon != null)
        'viewbox': '${lon - 2},${lat + 1.3},${lon + 2},${lat - 1.3}',
    });
    final res =
        await http.get(uri, headers: _ua).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return const [];
    return parseNominatim(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  static List<Place> parseNominatim(dynamic data) {
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
        kind: kindOf(e['category'] as String?, e['type'] as String?),
        lat: lat,
        lon: lon,
      ));
    }
    return out;
  }

  // -------------------------------------------------------------------
  //  Punkt -> Name
  // -------------------------------------------------------------------

  /// Name eines Punkts (fuer "auf der Karte waehlen"). null = unbekannt
  /// oder kein Netz.
  static Future<Place?> reverse(double lat, double lon) async {
    try {
      final uri = Uri.https('photon.komoot.io', '/reverse', {
        'lat': lat.toStringAsFixed(6),
        'lon': lon.toStringAsFixed(6),
        'lang': 'de',
      });
      final res = await http
          .get(uri, headers: _ua)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final l = parsePhoton(jsonDecode(utf8.decode(res.bodyBytes)));
        if (l.isNotEmpty) {
          final p = l.first;
          // Der gefundene Name, aber die gewaehlte Stelle.
          final far = distanceMeters(lat, lon, p.lat, p.lon) > 150;
          return Place(
            name: far ? 'Punkt bei ${p.name}' : p.name,
            detail: p.detail,
            kind: 'Punkt auf der Karte',
            lat: lat,
            lon: lon,
          );
        }
      }
    } catch (_) {
      // weiter unten ohne Namen
    }
    return null;
  }

  /// Entfernung als Text ("12 km", "850 m") - fuer die Trefferliste.
  static String distanceText(double m) => m < 1000
      ? '${(m / 50).round() * 50} m'
      : (m < 10000
          ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
          : '${(m / 1000).round()} km');

  static double distanceTo(Place p, double lat, double lon) =>
      distanceMeters(lat, lon, p.lat, p.lon);
}

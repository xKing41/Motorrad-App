import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import 'offline_maps.dart';
import 'tile_cache.dart';

// ---------------------------------------------------------------------------
//  VEKTORKARTE (OpenFreeMap), TAG UND NACHT
//
//  Statt fertiger Bilder kommen die Kartendaten selbst aufs Handy
//  (Strassen, Wald, Wasser, Namen als Linien und Flaechen) und werden
//  auf dem Handy gezeichnet:
//   * scharf in jeder Zoomstufe,
//   * Tag- und Nachtdarstellung aus DENSELBEN Daten - nachts blendet
//     eine weisse Karte im dunklen Helm,
//   * deutlich kleiner: Kacheln gibt es nur bis Zoomstufe 14, alles
//     darueber wird aus ihnen gezeichnet. Offline-Speichern einer Route
//     braucht so nur einen Bruchteil.
//
//  Quelle: OpenFreeMap (kostenlos, ohne Schluessel, ohne Limit fuer
//  normale Nutzung), Daten OpenStreetMap, Schema OpenMapTiles.
//  Stile: OpenFreeMap "liberty" (Tag) und "dark" (Nacht), angepasst
//  (tools/make_map_styles.py).
// ---------------------------------------------------------------------------

enum MapStyle { auto, day, night, classic }

extension MapStyleX on MapStyle {
  String get label => switch (this) {
        MapStyle.auto => 'Automatisch (Tag/Nacht nach Sonnenstand)',
        MapStyle.day => 'Vektorkarte hell',
        MapStyle.night => 'Vektorkarte dunkel',
        MapStyle.classic => 'Klassische OSM-Karte',
      };

  static MapStyle parse(String? s) =>
      MapStyle.values.firstWhere((m) => m.name == s, orElse: () => MapStyle.auto);
}

/// Sonnenhoehe in Grad ueber dem Horizont (NOAA-Naeherung, auf etwa ein
/// halbes Grad genau - reicht fuer "hell oder dunkel").
double sunElevationDeg(DateTime t, double lat, double lon) {
  final u = t.toUtc();
  final dayOfYear =
      u.difference(DateTime.utc(u.year, 1, 1)).inMinutes / 1440.0;
  final hour = u.hour + u.minute / 60 + u.second / 3600;
  final g = 2 * math.pi / 365 * (dayOfYear + (hour - 12) / 24);
  final decl = 0.006918 -
      0.399912 * math.cos(g) +
      0.070257 * math.sin(g) -
      0.006758 * math.cos(2 * g) +
      0.000907 * math.sin(2 * g) -
      0.002697 * math.cos(3 * g) +
      0.00148 * math.sin(3 * g);
  final eqTime = 229.18 *
      (0.000075 +
          0.001868 * math.cos(g) -
          0.032077 * math.sin(g) -
          0.014615 * math.cos(2 * g) -
          0.040849 * math.sin(2 * g));
  final trueSolar = hour * 60 + eqTime + 4 * lon;
  final ha = (trueSolar / 4 - 180) * math.pi / 180;
  final la = lat * math.pi / 180;
  final cosZen =
      math.sin(la) * math.sin(decl) + math.cos(la) * math.cos(decl) * math.cos(ha);
  return 90 - math.acos(cosZen.clamp(-1.0, 1.0)) * 180 / math.pi;
}

/// Dunkel genug fuer die Nachtkarte? Ab Sonnenstand unter -3 Grad
/// (buergerliche Daemmerung) - vorher ist es draussen noch hell genug.
bool isDark(DateTime t, double lat, double lon) =>
    sunElevationDeg(t, lat, lon) < -3;

/// Kacheln der Vektorkarte: erst vom Handy, dann aus dem Netz, im
/// Funkloch auch aeltere gespeicherte.
class CachedVectorProvider extends VectorTileProvider {
  CachedVectorProvider(this.urlTemplate, this.cacheFor, {http.Client? client})
      : _client = client ?? http.Client();

  final String urlTemplate;
  final Future<TileCache> Function() cacheFor;
  final http.Client _client;

  @override
  int get maximumZoom => VectorMap.maxDataZoom;

  @override
  int get minimumZoom => 0;

  String urlFor(TileKey k) => urlTemplate
      .replaceAll('{z}', '${k.z}')
      .replaceAll('{x}', '${k.x}')
      .replaceAll('{y}', '${k.y}');

  Future<Uint8List> fetch(TileKey k) async {
    final res = await _client.get(Uri.parse(urlFor(k)), headers: {
      'User-Agent': osmUserAgent,
    }).timeout(const Duration(seconds: 15));
    if (res.statusCode == 204 || res.statusCode == 404) {
      // Leere Kachel (Meer, kein Inhalt) - kein Fehler.
      return Uint8List(0);
    }
    if (res.statusCode != 200) {
      throw ProviderException(
          message: 'Kachel ${res.statusCode}',
          statusCode: res.statusCode,
          retryable: Retryable.retry);
    }
    return res.bodyBytes;
  }

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final k = TileKey(tile.z, tile.x, tile.y);
    final cache = await cacheFor();
    final fresh = await cache.read(k, maxAge: VectorMap.fresh);
    if (fresh != null) return fresh;
    try {
      final b = await fetch(k);
      OfflineMaps.instance.markOnline(true);
      if (b.isNotEmpty) unawaited(cache.write(k, b));
      return b;
    } catch (e) {
      OfflineMaps.instance.markOnline(false);
      final stale = await cache.read(k);
      if (stale != null) return stale;
      if (e is ProviderException) rethrow;
      throw ProviderException(
          message: 'Kein Netz', retryable: Retryable.retry);
    }
  }
}

class VectorMap extends ChangeNotifier {
  VectorMap._();
  static final VectorMap instance = VectorMap._();

  /// Hoechste Zoomstufe mit eigenen Daten (OpenFreeMap).
  static const int maxDataZoom = 14;

  /// Vektorkacheln aendern sich selten (Daten werden woechentlich
  /// erneuert) - einen Monat vom Handy nehmen.
  static const fresh = Duration(days: 30);

  static const String tileJsonUrl = 'https://tiles.openfreemap.org/planet';
  static const String attribution =
      'OpenFreeMap © OpenMapTiles © OpenStreetMap-Mitwirkende';

  static const _kStyle = 'map_style';
  static const _kTemplate = 'ofm_tile_template';

  MapStyle style = MapStyle.auto;
  String? _template;
  vtr.Theme? _day;
  vtr.Theme? _night;
  CachedVectorProvider? _provider;
  TileCache? _cache;
  Future<void>? _init;

  /// Kachel-Adresse bekannt (einmal online gewesen)?
  bool get ready => _template != null && _day != null && _night != null;

  Future<void> init() => _init ??= _load();

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    style = MapStyleX.parse(sp.getString(_kStyle));
    _template = sp.getString(_kTemplate);
    try {
      _day = themeFrom(await rootBundle.loadString('assets/map/style_day.json'));
      _night =
          themeFrom(await rootBundle.loadString('assets/map/style_night.json'));
    } catch (_) {
      _day = _night = null; // dann klassische Karte
    }
    if (_template != null) _makeProvider();
    notifyListeners();
    // Aktuelle Kachel-Adresse holen (OpenFreeMap versioniert sie).
    unawaited(_refreshTemplate(sp));
  }

  static vtr.Theme themeFrom(String json) =>
      vtr.ThemeReader().read(jsonDecode(json) as Map<String, dynamic>);

  /// Liest die Kachel-Adresse aus der TileJSON-Antwort.
  static String? templateFrom(Object? tileJson) {
    if (tileJson is! Map) return null;
    final tiles = tileJson['tiles'];
    if (tiles is! List || tiles.isEmpty || tiles.first is! String) return null;
    final t = tiles.first as String;
    return t.contains('{z}') && t.contains('{x}') && t.contains('{y}')
        ? t
        : null;
  }

  Future<void> _refreshTemplate(SharedPreferences sp) async {
    try {
      final res = await http.get(Uri.parse(tileJsonUrl), headers: {
        'User-Agent': osmUserAgent
      }).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return;
      final t = templateFrom(jsonDecode(utf8.decode(res.bodyBytes)));
      if (t == null || t == _template) return;
      _template = t;
      await sp.setString(_kTemplate, t);
      _makeProvider();
      notifyListeners();
    } catch (_) {
      // Offline: gespeicherte Adresse bleibt.
    }
  }

  Future<TileCache> cache() async {
    final c = _cache;
    if (c != null) return c;
    final base = await getApplicationSupportDirectory();
    return _cache = TileCache(Directory('${base.path}/tiles/ofm'));
  }

  void _makeProvider() {
    _provider = CachedVectorProvider(_template!, cache);
  }

  CachedVectorProvider? get provider => _provider;

  TileProviders? get tileProviders {
    final p = _provider;
    return p == null ? null : TileProviders({'openmaptiles': p});
  }

  Future<void> setStyle(MapStyle s) async {
    style = s;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kStyle, s.name);
  }

  /// Soll die Vektorkarte gezeigt werden?
  bool get useVector => style != MapStyle.classic && ready;

  /// Nachtdarstellung jetzt? [lat]/[lon]: Standort fuer den Sonnenstand.
  bool nightAt(DateTime t, double? lat, double? lon) => switch (style) {
        MapStyle.night => true,
        MapStyle.day || MapStyle.classic => false,
        // Ohne Standort: grob nach Uhrzeit.
        MapStyle.auto => lat != null && lon != null
            ? isDark(t, lat, lon)
            : (t.hour >= 21 || t.hour < 6),
      };

  vtr.Theme? theme({required bool night}) => night ? _night : _day;
}

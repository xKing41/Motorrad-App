import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_plan.dart';
import 'tile_cache.dart';

/// Kartenquelle (OpenStreetMap-Standardkarte).
const String osmUrlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String osmUserAgent = 'Schraeglage/4.15 (de.schraeglage.app)';

/// Stand eines Vorab-Downloads.
class OfflineJob {
  OfflineJob(this.label, this.total);
  final String label;
  final int total;
  int done = 0;
  PrefetchResult? result;
  bool get running => result == null;
  double get progress => total == 0 ? 1 : done / total;
}

/// Offline-Karten: Kachelspeicher, Vorab-Download und Einstellungen.
class OfflineMaps extends ChangeNotifier {
  OfflineMaps._();
  static final OfflineMaps instance = OfflineMaps._();

  static const _kAuto = 'offline_auto_route';

  /// Gemeinsame Kachelquelle fuer alle Karten der App.
  static final CachedTileProvider tiles = CachedTileProvider();

  /// Wie lange eine Kachel ohne Nachfrage beim Server benutzt wird.
  /// (Der OSM-Server gibt Kacheln fuer rund eine Woche frei.)
  static const fresh = Duration(days: 7);

  /// Hoechstzahl Kacheln je Vorab-Download (~150 MB).
  static const maxJobTiles = 9000;

  TileCache? _cache;
  Future<TileCache>? _opening;
  final http.Client _client = http.Client();

  /// Route beim Planen automatisch offline speichern.
  bool autoRoute = true;

  /// true, solange Kacheln nicht aus dem Netz kommen (Funkloch).
  final ValueNotifier<bool> offline = ValueNotifier(false);

  OfflineJob? job;
  bool _cancel = false;

  Future<TileCache> cache() => _opening ??= _open();

  Future<TileCache> _open() async {
    final base = await getApplicationSupportDirectory();
    final c = TileCache(Directory('${base.path}/tiles/osm'));
    _cache = c;
    final p = await SharedPreferences.getInstance();
    autoRoute = p.getBool(_kAuto) ?? true;
    // Aufraeumen im Hintergrund, falls der Speicher zu voll ist.
    unawaited(c.trim());
    return c;
  }

  /// Schon geoeffneter Speicher (synchron, fuer die Kachelanzeige).
  TileCache? get cacheNow => _cache;

  Future<void> setAutoRoute(bool v) async {
    autoRoute = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kAuto, v);
  }

  /// Eine Kachel vom Server holen.
  Future<Uint8List> fetch(TileKey k) async {
    final url = osmUrlTemplate
        .replaceAll('{z}', '${k.z}')
        .replaceAll('{x}', '${k.x}')
        .replaceAll('{y}', '${k.y}');
    final res = await _client
        .get(Uri.parse(url), headers: {'User-Agent': osmUserAgent})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
      throw http.ClientException('Kachel ${res.statusCode}', Uri.parse(url));
    }
    final type = res.headers['content-type'] ?? 'image/png';
    if (!type.startsWith('image/')) {
      throw http.ClientException('Keine Kachel', Uri.parse(url));
    }
    return res.bodyBytes;
  }

  void _markOnline(bool ok) {
    if (offline.value == ok) offline.value = !ok;
  }

  /// Kacheln entlang einer Route (Streifen links und rechts).
  Set<TileKey> routeTiles(List<RoutePoint> pts) {
    var keys = tilesAlongRoute(pts);
    // Sehr lange Touren: Streifen schmaler, notfalls ohne Stufe 16.
    if (keys.length > maxJobTiles) {
      keys = tilesAlongRoute(pts, bufferM: 150);
    }
    if (keys.length > maxJobTiles) {
      keys = tilesAlongRoute(pts, maxZoom: 15, bufferM: 200);
    }
    return keys;
  }

  /// Hoechste Zoomstufe, bei der der Ausschnitt in [maxJobTiles] passt.
  static int areaMaxZoom(
      double south, double west, double north, double east, int minZoom) {
    var z = maxPrefetchZoom;
    while (z > minZoom &&
        countTilesInBox(south, west, north, east,
                minZoom: minZoom, maxZoom: z) >
            maxJobTiles) {
      z--;
    }
    return z;
  }

  Future<PrefetchResult?> saveRoute(List<RoutePoint> pts,
      {String label = 'Route'}) async {
    if (pts.length < 2) return null;
    final keys = routeTiles(pts);
    return _run(label, prefetchOrder(keys, route: pts));
  }

  Future<PrefetchResult?> saveArea(
      double south, double west, double north, double east,
      {int minZoom = 8}) async {
    final z = areaMaxZoom(south, west, north, east, minZoom);
    final keys =
        tilesInBox(south, west, north, east, minZoom: minZoom, maxZoom: z);
    return _run('Kartenausschnitt', prefetchOrder(keys));
  }

  Future<PrefetchResult?> _run(String label, List<TileKey> keys) async {
    // Ein neuer Auftrag ersetzt einen laufenden.
    if (job?.running == true) {
      _cancel = true;
      while (job?.running == true) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    _cancel = false;
    final c = await cache();
    final j = OfflineJob(label, keys.length);
    job = j;
    notifyListeners();
    var lastNotify = 0;
    final res = await c.prefetch(
      keys,
      fetch,
      fresh: const Duration(days: 30),
      cancelled: () => _cancel,
      onProgress: (done, _) {
        j.done = done;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastNotify > 250) {
          lastNotify = now;
          notifyListeners();
        }
      },
    );
    j.result = res;
    if (res.loaded > 0) _markOnline(true);
    notifyListeners();
    unawaited(c.trim());
    return res;
  }

  void cancel() {
    _cancel = true;
  }

  Future<TileCacheStats> stats() async => (await cache()).stats();

  Future<void> clear() async {
    cancel();
    await (await cache()).clear();
    notifyListeners();
  }
}

/// Kachelquelle fuer flutter_map: erst der Speicher auf dem Handy, dann
/// das Netz - und ohne Netz eine groebere gespeicherte Kachel,
/// vergroessert, statt einer leeren Flaeche.
class CachedTileProvider extends TileProvider {
  CachedTileProvider({super.headers});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return CachedTileImage(
      TileKey(coordinates.z, coordinates.x, coordinates.y),
      getTileUrl(coordinates, options),
      headers,
    );
  }
}

@immutable
class CachedTileImage extends ImageProvider<CachedTileImage> {
  const CachedTileImage(this.key, this.url, this.headers);

  final TileKey key;
  final String url;
  final Map<String, String> headers;

  static const int _maxUpLevels = 6;

  @override
  Future<CachedTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
          CachedTileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: url,
      );

  Future<ui.Codec> _decode(Uint8List b, ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(b));

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final om = OfflineMaps.instance;
    final cache = await om.cache();

    // 1. Frische Kachel vom Handy - kein Netz noetig.
    final fresh = await cache.read(key, maxAge: OfflineMaps.fresh);
    if (fresh != null) return _decode(fresh, decode);

    // 2. Aus dem Netz holen und ablegen.
    Uint8List? net;
    try {
      final res = await om._client
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 10));
      final type = res.headers['content-type'] ?? 'image/png';
      if (res.statusCode == 200 &&
          res.bodyBytes.isNotEmpty &&
          type.startsWith('image/')) {
        net = res.bodyBytes;
      }
      om._markOnline(true);
    } catch (_) {
      om._markOnline(false);
    }
    if (net != null) {
      unawaited(cache.write(key, net));
      return _decode(net, decode);
    }

    // Ab hier: Notloesung. Nicht dauerhaft im Bildspeicher behalten,
    // damit mit Netz die richtige Kachel nachgeladen wird.
    scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));

    // 3. Aeltere Kachel vom Handy.
    final stale = await cache.read(key);
    if (stale != null) return _decode(stale, decode);

    // 4. Groebere Kachel, passend ausgeschnitten und vergroessert.
    for (var d = 1; d <= _maxUpLevels && key.z - d >= 0; d++) {
      final up = await cache.read(key.ancestor(d));
      if (up == null) continue;
      Uint8List? png;
      try {
        png = await cropAncestor(up, key, d);
      } catch (_) {
        break;
      }
      return _decode(png, decode);
    }
    return _decode(TileProvider.transparentImage, decode);
  }

  /// Schneidet aus der Kachel [d] Stufen groeber das Stueck fuer [k] aus
  /// und vergroessert es auf 256x256.
  static Future<Uint8List> cropAncestor(
      Uint8List bytes, TileKey k, int d) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final src = (await codec.getNextFrame()).image;
    final parts = 1 << d;
    final w = src.width / parts, h = src.height / parts;
    final ox = (k.x - (k.x >> d << d)) * w;
    final oy = (k.y - (k.y >> d << d)) * h;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawImageRect(
      src,
      ui.Rect.fromLTWH(ox, oy, w, h),
      const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final img = await rec.endRecording().toImage(256, 256);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    src.dispose();
    img.dispose();
    if (data == null) throw StateError('png');
    return data.buffer.asUint8List();
  }

  @override
  bool operator ==(Object other) =>
      other is CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Kurzer Text fuer eine Datenmenge ("35 MB").
String formatBytes(int b) {
  if (b < 1024 * 1024) return '${math.max(1, (b / 1024).round())} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).round()} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

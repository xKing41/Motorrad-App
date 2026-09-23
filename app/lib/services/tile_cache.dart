import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  KARTENKACHELN AUF DEM HANDY
//
//  Die Karte besteht aus 256x256-Bildern ("Kacheln") je Zoomstufe. Bisher
//  kamen sie nur aus dem Netz - im Funkloch (Schwarzwald, Alpen, Eifel)
//  war die Karte dann leer, genau dort, wo man sie am meisten braucht.
//  Jetzt wird jede Kachel, die einmal geladen wurde, auf dem Handy
//  abgelegt, und Route oder Kartenausschnitt koennen vorab geladen werden.
//
//  Regeln des OpenStreetMap-Kachelservers (tile.openstreetmap.org) werden
//  eingehalten: hoechstens 2 gleichzeitige Downloads, vorab nur bis
//  Zoomstufe 16, eindeutige App-Kennung, bereits vorhandene Kacheln werden
//  nicht erneut geholt.
// ---------------------------------------------------------------------------

/// Eine Kachel: Zoomstufe und Spalte/Zeile im Kachelraster.
class TileKey {
  const TileKey(this.z, this.x, this.y);
  final int z;
  final int x;
  final int y;

  /// Die Kachel eine Zoomstufe groeber, die diese enthaelt.
  TileKey ancestor(int levels) => TileKey(z - levels, x >> levels, y >> levels);

  @override
  bool operator ==(Object other) =>
      other is TileKey && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => '$z/$x/$y';
}

/// Hoechste Zoomstufe, die vorab geladen wird (Regel des OSM-Servers:
/// ab 17 nicht in groesseren Mengen). Staerker hineingezoomt wird aus der
/// Kachel dieser Stufe vergroessert.
const int maxPrefetchZoom = 16;

/// Bruchteilige Kachelposition eines Orts (x, y) bei Zoomstufe [z].
(double, double) tileXY(double lat, double lon, int z) {
  final n = (1 << z).toDouble();
  final la = lat.clamp(-85.0511, 85.0511) * math.pi / 180;
  final x = (lon + 180) / 360 * n;
  final y = (1 - math.log(math.tan(la) + 1 / math.cos(la)) / math.pi) / 2 * n;
  return (x.clamp(0.0, n - 1e-9), y.clamp(0.0, n - 1e-9));
}

TileKey tileAt(double lat, double lon, int z) {
  final (x, y) = tileXY(lat, lon, z);
  return TileKey(z, x.floor(), y.floor());
}

/// Kantenlaenge einer Kachel in Metern an der Breite [lat].
double tileSizeM(double lat, int z) =>
    40075016.686 * math.cos(lat * math.pi / 180) / (1 << z);

/// Alle Kacheln eines Streifens um die Route: je Zoomstufe alles, was
/// naeher als [bufferM] an der Linie liegt. So bleibt beim Fahren links
/// und rechts genug Karte sichtbar.
Set<TileKey> tilesAlongRoute(
  List<RoutePoint> pts, {
  int minZoom = 11,
  int maxZoom = maxPrefetchZoom,
  double bufferM = 300,
}) {
  final out = <TileKey>{};
  if (pts.isEmpty) return out;
  final cum = cumulativeDistances(pts);
  final total = cum.last;
  for (var z = minZoom; z <= math.min(maxZoom, maxPrefetchZoom); z++) {
    final n = 1 << z;
    // Abtastung: mehrmals je Kachel, damit keine an Ecken verloren geht.
    final step = math.max(20.0, tileSizeM(pts.first.lat, z) / 4);
    for (var d = 0.0;; d += step) {
      final p = pointAlong(pts, cum, math.min(d, total));
      final (fx, fy) = tileXY(p.lat, p.lon, z);
      final b = bufferM / tileSizeM(p.lat, z);
      final x0 = (fx - b).floor(), x1 = (fx + b).floor();
      final y0 = (fy - b).floor(), y1 = (fy + b).floor();
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          if (y < 0 || y >= n) continue;
          out.add(TileKey(z, x % n, y));
        }
      }
      if (d >= total) break;
    }
  }
  return out;
}

/// Kacheln eines Kartenausschnitts fuer die Zoomstufen [minZoom]..[maxZoom].
Set<TileKey> tilesInBox(double south, double west, double north, double east,
    {required int minZoom, required int maxZoom}) {
  final out = <TileKey>{};
  for (var z = minZoom; z <= math.min(maxZoom, maxPrefetchZoom); z++) {
    final a = tileAt(north, west, z), b = tileAt(south, east, z);
    for (var x = a.x; x <= b.x; x++) {
      for (var y = a.y; y <= b.y; y++) {
        out.add(TileKey(z, x, y));
      }
    }
  }
  return out;
}

/// Anzahl Kacheln eines Ausschnitts - ohne sie alle anzulegen.
int countTilesInBox(double south, double west, double north, double east,
    {required int minZoom, required int maxZoom}) {
  var n = 0;
  for (var z = minZoom; z <= math.min(maxZoom, maxPrefetchZoom); z++) {
    final a = tileAt(north, west, z), b = tileAt(south, east, z);
    n += (b.x - a.x + 1) * (b.y - a.y + 1);
  }
  return n;
}

/// Durchschnittliche Groesse einer OSM-Kachel - fuer Schaetzungen.
const int avgTileBytes = 16 * 1024;

class TileCacheStats {
  const TileCacheStats(this.tiles, this.bytes);
  final int tiles;
  final int bytes;
}

class PrefetchResult {
  const PrefetchResult(
      {this.loaded = 0, this.skipped = 0, this.failed = 0, this.cancelled = false});
  final int loaded;
  final int skipped;
  final int failed;
  final bool cancelled;
  int get total => loaded + skipped + failed;
}

/// Kachelspeicher auf dem Handy: eine Datei je Kachel unter z/x/y.png.
class TileCache {
  TileCache(this.dir);

  final Directory dir;

  /// Speicherobergrenze; darueber werden die am laengsten nicht mehr
  /// gebrauchten Kacheln geloescht.
  static const int defaultMaxBytes = 600 * 1024 * 1024;

  File fileFor(TileKey k) => File('${dir.path}/${k.z}/${k.x}/${k.y}.png');

  /// Gespeicherte Kachel oder null. Mit [maxAge] nur, wenn sie
  /// hoechstens so alt ist.
  Future<Uint8List?> read(TileKey k, {Duration? maxAge}) async {
    final f = fileFor(k);
    try {
      if (maxAge != null) {
        final age = DateTime.now().difference(await f.lastModified());
        if (age > maxAge) return null;
      }
      final b = await f.readAsBytes();
      return b.isEmpty ? null : b;
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> has(TileKey k, {Duration? maxAge}) async {
    final f = fileFor(k);
    try {
      final st = await f.stat();
      if (st.type != FileSystemEntityType.file || st.size == 0) return false;
      if (maxAge == null) return true;
      return DateTime.now().difference(st.modified) <= maxAge;
    } on FileSystemException {
      return false;
    }
  }

  /// Legt eine Kachel ab. Erst in eine Hilfsdatei, dann umbenennen - so
  /// bleibt bei vollem Speicher oder Absturz keine halbe Kachel liegen.
  Future<void> write(TileKey k, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    final f = fileFor(k);
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: false);
      await tmp.rename(f.path);
    } on FileSystemException {
      // Speicher voll o. ae.: die Karte funktioniert trotzdem.
    }
  }

  Future<List<File>> _files() async {
    if (!await dir.exists()) return const [];
    return [
      await for (final e in dir.list(recursive: true, followLinks: false))
        if (e is File && e.path.endsWith('.png')) e,
    ];
  }

  Future<TileCacheStats> stats() async {
    var n = 0, bytes = 0;
    for (final f in await _files()) {
      try {
        bytes += await f.length();
        n++;
      } on FileSystemException {
        // gerade geloescht
      }
    }
    return TileCacheStats(n, bytes);
  }

  /// Haelt den Speicher unter [maxBytes]: loescht die aeltesten Kacheln,
  /// bis nur noch 80 % belegt sind. Gibt die Zahl geloeschter Kacheln
  /// zurueck.
  Future<int> trim([int maxBytes = defaultMaxBytes]) async {
    final entries = <(File, int, DateTime)>[];
    var total = 0;
    for (final f in await _files()) {
      try {
        final st = await f.stat();
        entries.add((f, st.size, st.modified));
        total += st.size;
      } on FileSystemException {
        // weg
      }
    }
    if (total <= maxBytes) return 0;
    entries.sort((a, b) => a.$3.compareTo(b.$3));
    final goal = maxBytes * 0.8;
    var removed = 0;
    for (final (f, size, _) in entries) {
      if (total <= goal) break;
      try {
        await f.delete();
        total -= size;
        removed++;
      } on FileSystemException {
        // egal
      }
    }
    return removed;
  }

  Future<void> clear() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // egal
    }
  }

  /// Laedt [keys] vorab. Vorhandene Kacheln, die juenger als [fresh]
  /// sind, werden uebersprungen. Hoechstens [concurrency] Downloads
  /// gleichzeitig (OSM-Regel: 2).
  Future<PrefetchResult> prefetch(
    List<TileKey> keys,
    Future<Uint8List> Function(TileKey) fetch, {
    int concurrency = 2,
    Duration fresh = const Duration(days: 30),
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    var next = 0, loaded = 0, skipped = 0, failed = 0, done = 0;
    var failStreak = 0;
    var stop = false;

    Future<void> worker() async {
      while (!stop) {
        if (cancelled?.call() == true) {
          stop = true;
          return;
        }
        if (next >= keys.length) return;
        final k = keys[next++];
        if (await has(k, maxAge: fresh)) {
          skipped++;
        } else {
          try {
            final b = await fetch(k);
            await write(k, b);
            loaded++;
            failStreak = 0;
          } catch (_) {
            failed++;
            // Kein Netz mehr: nicht tausende Fehlversuche hinterher.
            if (++failStreak >= 20) stop = true;
          }
        }
        done++;
        onProgress?.call(done, keys.length);
      }
    }

    await Future.wait(
        [for (var i = 0; i < math.max(1, concurrency); i++) worker()]);
    return PrefetchResult(
      loaded: loaded,
      skipped: skipped,
      failed: failed,
      cancelled: cancelled?.call() == true || (stop && done < keys.length),
    );
  }
}

/// Sortiert Kacheln so, dass grobe Zoomstufen zuerst kommen - bricht der
/// Download ab, gibt es wenigstens ueberall eine Uebersicht - und
/// innerhalb einer Stufe entlang der Route von vorn nach hinten.
List<TileKey> prefetchOrder(Set<TileKey> keys, {List<RoutePoint>? route}) {
  final list = keys.toList();
  if (route == null || route.isEmpty) {
    list.sort((a, b) => a.z != b.z
        ? a.z.compareTo(b.z)
        : (a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x)));
    return list;
  }
  // Reihenfolge entlang der Route: Index des ersten Routenpunkts je
  // Kachel.
  final firstSeen = <TileKey, int>{};
  final zooms = {for (final k in keys) k.z};
  for (final z in zooms) {
    for (var i = 0; i < route.length; i++) {
      final k = tileAt(route[i].lat, route[i].lon, z);
      firstSeen.putIfAbsent(k, () => i);
    }
  }
  int rank(TileKey k) {
    final direct = firstSeen[k];
    if (direct != null) return direct;
    // Randkachel: Rang der naechsten Nachbarkachel auf der Route.
    var best = route.length;
    for (var dx = -2; dx <= 2; dx++) {
      for (var dy = -2; dy <= 2; dy++) {
        final r = firstSeen[TileKey(k.z, k.x + dx, k.y + dy)];
        if (r != null && r < best) best = r;
      }
    }
    return best;
  }

  final ranks = {for (final k in list) k: rank(k)};
  list.sort((a, b) =>
      a.z != b.z ? a.z.compareTo(b.z) : ranks[a]!.compareTo(ranks[b]!));
  return list;
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/tile_cache.dart';

void main() {
  group('Kachelmathematik', () {
    test('bekannte Kachel: Berlin Zoom 10', () {
      // Berlin Mitte liegt bei z10 in Kachel 550/335.
      final k = tileAt(52.52, 13.405, 10);
      expect(k, const TileKey(10, 550, 335));
    });

    test('Vorfahr enthaelt die Kachel', () {
      const k = TileKey(16, 34567, 22222);
      final up = k.ancestor(3);
      expect(up.z, 13);
      expect(up.x, 34567 >> 3);
      expect(up.y, 22222 >> 3);
    });

    test('Ausschnitt: Zahl und Liste stimmen ueberein', () {
      final n = countTilesInBox(48.0, 8.0, 48.2, 8.3, minZoom: 10, maxZoom: 14);
      final keys = tilesInBox(48.0, 8.0, 48.2, 8.3, minZoom: 10, maxZoom: 14);
      expect(keys.length, n);
      expect(keys.map((k) => k.z).toSet(), {10, 11, 12, 13, 14});
    });

    test('nie ueber Stufe 16 vorab', () {
      final keys = tilesInBox(48.0, 8.0, 48.01, 8.01, minZoom: 15, maxZoom: 19);
      expect(keys.every((k) => k.z <= maxPrefetchZoom), isTrue);
    });

    test('Routenstreifen deckt jeden Routenpunkt ab', () {
      final route = [
        for (var i = 0; i <= 50; i++) RoutePoint(48.0 + i * 0.002, 8.0 + i * 0.003),
      ];
      final keys = tilesAlongRoute(route, minZoom: 12, maxZoom: 16);
      for (final p in route) {
        for (var z = 12; z <= 16; z++) {
          expect(keys.contains(tileAt(p.lat, p.lon, z)), isTrue,
              reason: '$p z$z');
        }
      }
      // Streifen, nicht Rechteck: deutlich weniger als die Box.
      final box = countTilesInBox(48.0, 8.0, 48.1, 8.15, minZoom: 12, maxZoom: 16);
      expect(keys.length, lessThan(box));
    });

    test('Reihenfolge: grobe Stufen zuerst, dann entlang der Route', () {
      final route = [
        for (var i = 0; i <= 40; i++) RoutePoint(48.0, 8.0 + i * 0.01),
      ];
      final order = prefetchOrder(
          tilesAlongRoute(route, minZoom: 13, maxZoom: 15),
          route: route);
      for (var i = 1; i < order.length; i++) {
        expect(order[i].z, greaterThanOrEqualTo(order[i - 1].z));
      }
      final z15 = order.where((k) => k.z == 15).toList();
      // Von West nach Ost gefahren: Spalten steigen im Schnitt.
      expect(z15.first.x, lessThan(z15.last.x));
    });
  });

  group('Kachelspeicher', () {
    late Directory dir;
    late TileCache cache;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('tiles');
      cache = TileCache(dir);
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Uint8List bytes(int n, [int v = 1]) => Uint8List.fromList(List.filled(n, v));

    test('schreiben, lesen, Alter', () async {
      const k = TileKey(12, 1, 2);
      expect(await cache.read(k), isNull);
      await cache.write(k, bytes(10));
      expect((await cache.read(k))!.length, 10);
      expect(await cache.has(k), isTrue);
      cache.fileFor(k).setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 10)));
      expect(await cache.read(k, maxAge: const Duration(days: 7)), isNull);
      expect(await cache.read(k), isNotNull);
      expect(await cache.has(k, maxAge: const Duration(days: 7)), isFalse);
    });

    test('Aufraeumen loescht die aeltesten zuerst', () async {
      for (var i = 0; i < 10; i++) {
        final k = TileKey(10, i, 0);
        await cache.write(k, bytes(1000));
        cache.fileFor(k).setLastModifiedSync(
            DateTime.now().subtract(Duration(hours: 10 - i)));
      }
      final removed = await cache.trim(5000);
      final s = await cache.stats();
      expect(removed, 6);
      expect(s.bytes, lessThanOrEqualTo(4000));
      expect(await cache.has(const TileKey(10, 0, 0)), isFalse);
      expect(await cache.has(const TileKey(10, 9, 0)), isTrue);
    });

    test('Vorab laden: vorhandene ueberspringen, Fehler zaehlen', () async {
      await cache.write(const TileKey(10, 0, 0), bytes(5));
      final keys = [for (var i = 0; i < 6; i++) TileKey(10, i, 0)];
      var active = 0, maxActive = 0;
      final res = await cache.prefetch(keys, (k) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        if (k.x == 3) throw Exception('404');
        return bytes(7);
      });
      expect(res.skipped, 1);
      expect(res.loaded, 4);
      expect(res.failed, 1);
      expect(res.cancelled, isFalse);
      expect(maxActive, lessThanOrEqualTo(2));
      expect((await cache.read(const TileKey(10, 5, 0)))!.length, 7);
    });

    test('ohne Netz: bricht nach einer Fehlerserie ab', () async {
      final keys = [for (var i = 0; i < 200; i++) TileKey(12, i, 0)];
      var calls = 0;
      final res = await cache.prefetch(keys, (k) async {
        calls++;
        throw const SocketException('offline');
      });
      expect(res.cancelled, isTrue);
      expect(calls, lessThan(30));
    });

    test('abbrechen', () async {
      final keys = [for (var i = 0; i < 50; i++) TileKey(12, i, 0)];
      var n = 0;
      final res = await cache.prefetch(keys, (k) async {
        n++;
        return bytes(3);
      }, cancelled: () => n >= 5);
      expect(res.cancelled, isTrue);
      expect(res.loaded, lessThan(10));
    });
  });
}

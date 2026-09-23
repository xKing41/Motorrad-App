import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schraeglage/services/tile_cache.dart';
import 'package:schraeglage/services/vector_map.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Tag- und Nachtstil lassen sich lesen und nutzen die Quelle', () {
    for (final f in ['assets/map/style_day.json', 'assets/map/style_night.json']) {
      final t = VectorMap.themeFrom(File(f).readAsStringSync());
      expect(t.layers.length, greaterThan(30), reason: f);
      expect(t.tileSources, {'openmaptiles'}, reason: f);
    }
  });

  test('Sonnenstand: Mittag hell, Mitternacht dunkel, Daemmerung', () {
    // Dortmund, Sommer (MESZ = UTC+2).
    const lat = 51.51, lon = 7.47;
    expect(sunElevationDeg(DateTime.utc(2026, 6, 21, 11, 30), lat, lon),
        greaterThan(55));
    expect(isDark(DateTime.utc(2026, 6, 21, 22, 0), lat, lon), isTrue);
    expect(isDark(DateTime.utc(2026, 6, 21, 12, 0), lat, lon), isFalse);
    // Sonnenuntergang Dortmund 21.6. ca. 21:50 MESZ = 19:50 UTC:
    // kurz danach noch hell genug, eine Stunde spaeter dunkel.
    expect(isDark(DateTime.utc(2026, 6, 21, 19, 55), lat, lon), isFalse);
    expect(isDark(DateTime.utc(2026, 6, 21, 21, 0), lat, lon), isTrue);
    // Winter, 17 Uhr MEZ: schon dunkel.
    expect(isDark(DateTime.utc(2026, 12, 21, 16, 0), lat, lon), isTrue);
  });

  test('Kachel-Adresse aus TileJSON', () {
    expect(
        VectorMap.templateFrom({
          'tiles': ['https://tiles.openfreemap.org/planet/20260917_001001_pt/{z}/{x}/{y}.pbf'],
        }),
        'https://tiles.openfreemap.org/planet/20260917_001001_pt/{z}/{x}/{y}.pbf');
    expect(VectorMap.templateFrom({'tiles': ['https://x/nope.pbf']}), isNull);
    expect(VectorMap.templateFrom('kaputt'), isNull);
  });

  group('Kachel-Lader', () {
    late Directory dir;
    late TileCache cache;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('vec');
      cache = TileCache(dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('Netz, dann vom Handy; ohne Netz aeltere gespeicherte', () async {
      var calls = 0;
      var online = true;
      final client = MockClient((req) async {
        calls++;
        expect(req.url.toString(), 'https://t/9/1/2.pbf');
        if (!online) throw http.ClientException('offline');
        return http.Response.bytes([1, 2, 3], 200);
      });
      final p = CachedVectorProvider('https://t/{z}/{x}/{y}.pbf',
          () async => cache,
          client: client);
      expect(await p.provide(TileIdentity(9, 1, 2)), [1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await p.provide(TileIdentity(9, 1, 2)), [1, 2, 3]);
      expect(calls, 1);
      // Alt und kein Netz: gespeicherte Kachel.
      cache.fileFor(const TileKey(9, 1, 2)).setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 60)));
      online = false;
      expect(await p.provide(TileIdentity(9, 1, 2)), [1, 2, 3]);
      // Nie gespeichert und kein Netz: Fehler, den die Karte kennt.
      expect(p.provide(TileIdentity(9, 5, 5)),
          throwsA(isA<ProviderException>()));
    });

    test('leere Kachel (Meer) ist kein Fehler', () async {
      final client =
          MockClient((req) async => http.Response.bytes(Uint8List(0), 204));
      final p = CachedVectorProvider('https://t/{z}/{x}/{y}.pbf',
          () async => cache,
          client: client);
      expect(await p.provide(TileIdentity(5, 1, 1)), isEmpty);
    });
  });
}

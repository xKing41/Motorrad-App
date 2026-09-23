import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/services/offline_maps.dart';
import 'package:schraeglage/services/tile_cache.dart';

/// Kachel mit vier farbigen Vierteln.
Future<Uint8List> quadrants() async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  const colors = [
    ui.Color(0xFFFF0000), ui.Color(0xFF00FF00), // oben: rot, gruen
    ui.Color(0xFF0000FF), ui.Color(0xFFFFFF00), // unten: blau, gelb
  ];
  for (var i = 0; i < 4; i++) {
    c.drawRect(ui.Rect.fromLTWH((i % 2) * 128.0, (i ~/ 2) * 128.0, 128, 128),
        ui.Paint()..color = colors[i]);
  }
  final img = await rec.endRecording().toImage(256, 256);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  return d!.buffer.asUint8List();
}

Future<List<int>> centerRgb(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final img = (await codec.getNextFrame()).image;
  expect(img.width, 256);
  final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  const o = (128 * 256 + 128) * 4;
  return [d.getUint8(o), d.getUint8(o + 1), d.getUint8(o + 2)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Ersatzkachel: richtiges Viertel der groeberen Kachel', () async {
    final parent = await quadrants();
    // Elternkachel 10/100/200 -> Kinder bei 11: x 200/201, y 400/401.
    const cases = [
      (TileKey(11, 200, 400), [255, 0, 0]),
      (TileKey(11, 201, 400), [0, 255, 0]),
      (TileKey(11, 200, 401), [0, 0, 255]),
      (TileKey(11, 201, 401), [255, 255, 0]),
    ];
    for (final (key, rgb) in cases) {
      final out = await CachedTileImage.cropAncestor(parent, key, 1);
      expect(await centerRgb(out), rgb, reason: '$key');
    }
  });

  test('Datenmengen lesbar', () {
    expect(formatBytes(500), '1 KB');
    expect(formatBytes(35 * 1024 * 1024), '35 MB');
    expect(formatBytes(3 * 1024 * 1024 * 1024 ~/ 2), '1.5 GB');
  });
}

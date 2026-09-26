import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/offline_router.dart';
import 'package:schraeglage/services/tile_cache.dart';
import 'package:vector_tile/raw/raw_vector_tile.dart' as raw;

/// Kachel-Geometrie kodieren (MVT: MoveTo, LineTo, Zickzack-Deltas).
List<int> line(List<(int, int)> pts) {
  int zz(int v) => (v << 1) ^ (v >> 31);
  final out = <int>[9, zz(pts[0].$1), zz(pts[0].$2)];
  out.add(2 | ((pts.length - 1) << 3));
  for (var i = 1; i < pts.length; i++) {
    out
      ..add(zz(pts[i].$1 - pts[i - 1].$1))
      ..add(zz(pts[i].$2 - pts[i - 1].$2));
  }
  return out;
}

/// Kachel mit Strassen: (Punkte, Klasse, oneway).
Uint8List tile(List<(List<(int, int)>, String, int)> roads) {
  final keys = ['class', 'oneway'];
  final values = <raw.VectorTile_Value>[];
  int val(raw.VectorTile_Value v) {
    values.add(v);
    return values.length - 1;
  }

  final feats = [
    for (final (pts, cls, ow) in roads)
      raw.VectorTile_Feature(
        type: raw.VectorTile_GeomType.LINESTRING,
        tags: [
          0,
          val(raw.VectorTile_Value(stringValue: cls)),
          1,
          val(raw.VectorTile_Value(doubleValue: ow.toDouble())),
        ],
        geometry: line(pts),
      ),
  ];
  return raw.VectorTile(layers: [
    raw.VectorTile_Layer(
        name: 'transportation',
        extent: 4096,
        version: 2,
        keys: keys,
        values: values,
        features: feats),
  ]).writeToBuffer();
}

void main() {
  final t = tileAt(51.0, 7.0, roadZoom);
  RoutePoint at(int x, int y) => gridToLatLon(t.x * 4096 + x, t.y * 4096 + y);

  test('Kachel lesen: Strassen mit Art und Einbahn', () {
    final b = tile([
      ([(0, 2000), (4095, 2000)], 'secondary', 0),
      ([(2000, 0), (2000, 2000)], 'minor', 1),
      ([(100, 100), (200, 200)], 'path', 0), // Fussweg: nicht dabei
    ]);
    final roads = roadsFromTile(b, t.x, t.y);
    expect(roads.length, 2);
    expect(roads[0].cls, 'secondary');
    expect(roads[1].oneway, 1);
    expect(roads[0].nodes.first, (t.x * 4096, t.y * 4096 + 2000));
  });

  test('Einbahnstrasse nur in einer Richtung', () {
    final net = RoadNet.build([
      RoadLine([(0, 0), (1000, 0)], 'minor', 1),
    ]);
    expect(net.shortest([0], {1: 0}), [0, 1]);
    expect(net.shortest([1], {0: 0}), isNull);
  });

  test('Rueckfuehrung zur Tour ueber das Strassennetz', () async {
    // Tour laeuft auf der Querstrasse nach Osten. Der Fahrer ist auf der
    // Nord-Sued-Strasse nach Norden abgebogen (bei x=1500).
    final b = tile([
      ([(0, 2000), (1500, 2000), (3000, 2000), (4095, 2000)], 'secondary', 0),
      ([(1500, 2000), (1500, 1000), (1500, 500)], 'minor', 0),
      ([(1500, 1000), (3000, 1000)], 'minor', 0),
      ([(3000, 1000), (3000, 2000)], 'minor', 0),
    ]);
    final route = [at(0, 2000), at(1500, 2000), at(3000, 2000), at(4095, 2000)];
    final cum = cumulativeDistances(route);
    final here = at(1500, 700);
    final r = OfflineRerouter((k) async => k == t ? b : null);
    final res = await r.rejoin(
        here: here, route: route, fromAlongM: cum[1] - 20);
    expect(res, isNotNull);
    // Startet beim Fahrer, endet auf der Tour.
    expect(dist(res!.points.first, here), lessThan(160));
    final end = projectOnPolyline(res.points.last, route, cum)!;
    expect(end.distanceM, lessThan(25));
    expect(res.joinAlongM, greaterThan(cum[1]));
    // Abbiegehinweise aus der Linie.
    final steps = stepsFromLine(res.points);
    expect(steps.first.type, ManeuverType.start);
    expect(steps.length, greaterThanOrEqualTo(2));
  });

  test('keine Kacheln gespeichert: keine Rueckfuehrung', () async {
    final r = OfflineRerouter((k) async => null);
    final res = await r.rejoin(
        here: at(1500, 700),
        route: [at(0, 2000), at(4095, 2000)],
        fromAlongM: 0);
    expect(res, isNull);
  });
}

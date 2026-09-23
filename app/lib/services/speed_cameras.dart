import '../models/route_plan.dart';
import 'poi_service.dart';

// ---------------------------------------------------------------------------
//  FESTE BLITZER (OpenStreetMap)
//
//  Rechtlich: In Deutschland ist es dem Fahrer verboten, waehrend der
//  Fahrt eine Blitzerwarnung zu nutzen (§ 23 Abs. 1c StVO), in Oesterreich
//  und der Schweiz ebenso. Erlaubt ist, sich VOR der Fahrt zu informieren.
//  Die App zeigt die Standorte deshalb nur bei der Planung - sobald
//  Navigation oder Aufzeichnung laufen, sind sie ausgeblendet. Es gibt
//  keine Ansage und keinen Warnton.
// ---------------------------------------------------------------------------

class SpeedCamera {
  const SpeedCamera(this.point, {this.kmh, this.id = ''});
  final RoutePoint point;
  final int? kmh;
  final String id;
}

class SpeedCameras {
  /// Overpass-Abfrage fuer feste Blitzer im Streifen um die Route.
  static String query(List<RoutePoint> route, {double corridorM = 150}) {
    final area = PoiService.corridor(route, corridorM);
    return '[out:json][timeout:25];'
        '(node["highway"="speed_camera"]$area;'
        'node["enforcement"="maxspeed"]$area;);out 500;';
  }

  static List<SpeedCamera> parse(Map<String, dynamic> data) {
    final out = <SpeedCamera>[];
    final seen = <String>{};
    for (final e in ((data['elements'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()) {
      final lat = (e['lat'] as num?)?.toDouble();
      final lon = (e['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      // Dasselbe Geraet mehrfach eingetragen: nur einmal.
      final key = '${(lat * 5000).round()}:${(lon * 5000).round()}';
      if (!seen.add(key)) continue;
      final tags = (e['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final ms = int.tryParse('${tags['maxspeed'] ?? ''}'.split(' ').first);
      out.add(SpeedCamera(RoutePoint(lat, lon), kmh: ms, id: '${e['id']}'));
    }
    return out;
  }

  /// Blitzer entlang der Route; null = Suche fehlgeschlagen.
  static Future<List<SpeedCamera>?> alongRoute(List<RoutePoint> route) async {
    if (route.length < 2) return const [];
    final data = await PoiService.overpass(query(route));
    return data == null ? null : parse(data);
  }
}

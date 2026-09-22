import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/ride.dart';
import '../models/route_plan.dart';
import 'poi_service.dart';

/// Schnittstelle fuer alle Routenplaner.
/// Dadurch laesst sich die Engine austauschen, ohne die App anzufassen:
/// heute GraphHopper, morgen etwas anderes.
abstract class RoutePlanner {
  Future<RoutePlan> plan(RouteRequest req);
}

/// Fehler bei der Routenberechnung - mit Text, der dem Fahrer
/// direkt angezeigt werden kann.
class RouteException implements Exception {
  RouteException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Anbindung an eine GraphHopper-Instanz.
///
/// Zwei Betriebsarten:
///  a) offizielle API:  baseUrl = 'https://graphhopper.com/api/1', apiKey setzen
///  b) eigener Server:  baseUrl = 'http://<host>:8989', apiKey null
///
/// Der Kurven-Wunsch wird in ein Custom Model uebersetzt. GraphHopper
/// kennt dafuer den Wert 'curvature' (Luftlinie / Streckenlaenge) -
/// je kleiner, desto kurviger die Strasse.
class GraphHopperPlanner implements RoutePlanner {
  GraphHopperPlanner({required this.baseUrl, this.apiKey});

  final String baseUrl;
  final String? apiKey;

  @override
  Future<RoutePlan> plan(RouteRequest req) async {
    final uri = Uri.parse(
      '$baseUrl/route${apiKey != null ? '?key=$apiKey' : ''}',
    );

    final custom = req.curviness.toGraphHopperCustomModel();
    final priority =
        (custom['priority'] as List).cast<Map<String, dynamic>>().toList();
    if (req.avoidUnpaved) {
      priority.add({'if': 'road_class == TRACK', 'multiply_by': '0.05'});
    }
    // Der Schalter "Autobahnen meiden" hat vorher nichts bewirkt: Er setzte
    // nur ch.disable, das sowieso schon true ist. Jetzt landet er als echte
    // Regel im Custom Model.
    if (req.avoidMotorways) {
      priority.add({'if': 'road_class == MOTORWAY', 'multiply_by': '0.05'});
    }
    custom['priority'] = priority;

    final body = <String, dynamic>{
      'profile': 'car',
      'points_encoded': false,
      'instructions': true,
      'locale': 'de',
      'ch.disable': true, // Pflicht, sobald ein Custom Model genutzt wird
      'custom_model': custom,
    };

    if (req.roundTrip) {
      body['points'] = [
        [req.startLon, req.startLat]
      ];
      body['algorithm'] = 'round_trip';
      body['round_trip.distance'] = (req.distanceKm * 1000).round();
      body['round_trip.seed'] = DateTime.now().millisecondsSinceEpoch % 100000;
    } else {
      body['points'] = [
        [req.startLon, req.startLat],
        [req.endLon ?? req.startLon, req.endLat ?? req.startLat],
      ];
    }

    http.Response res;
    try {
      res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw RouteException(
          'Routing-Server nicht erreichbar. Internetverbindung pruefen.');
    }

    if (res.statusCode != 200) {
      throw RouteException(
          'Routing fehlgeschlagen (Code ${res.statusCode}). '
          'Server-Adresse und Schluessel pruefen.');
    }

    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final paths = (data['paths'] as List?) ?? const [];
    if (paths.isEmpty) {
      throw RouteException('Keine Route gefunden. Andere Vorgaben versuchen.');
    }

    final p = paths.first as Map<String, dynamic>;
    final coords = ((p['points']?['coordinates']) as List?) ?? const [];
    final pts = <RoutePoint>[];
    for (final c in coords) {
      if (c is List && c.length >= 2) {
        pts.add(RoutePoint(
          (c[1] as num).toDouble(),
          (c[0] as num).toDouble(),
        ));
      }
    }

    final steps = <RouteStep>[];
    for (final i in ((p['instructions'] as List?) ?? const [])) {
      if (i is! Map) continue;
      steps.add(RouteStep(
        text: (i['text'] ?? '').toString(),
        distanceM: (i['distance'] as num?)?.toDouble() ?? 0,
        pointIndex: ((i['interval'] as List?)?.first as num?)?.toInt() ?? 0,
      ));
    }

    return RoutePlan(
      points: pts,
      distanceM: (p['distance'] as num?)?.toDouble() ?? 0,
      durationSec: (((p['time'] as num?)?.toDouble() ?? 0) / 1000).round(),
      steps: steps,
      title: req.title ?? 'Geplante Route',
    );
  }
}

/// Planer ohne Server: erzeugt eine grobe Rundtour aus Kreispunkten.
///
/// Damit ist die Karten- und Follow-Funktion sofort testbar, auch bevor
/// eine Routing-Engine steht. Er folgt KEINEN echten Strassen und ist
/// nur zum Ausprobieren der Oberflaeche gedacht.
class DemoLoopPlanner implements RoutePlanner {
  @override
  Future<RoutePlan> plan(RouteRequest req) async {
    final radiusM = (req.distanceKm * 1000) / (2 * math.pi);
    final pts = <RoutePoint>[];
    const steps = 90;
    for (var i = 0; i <= steps; i++) {
      final a = 2 * math.pi * i / steps;
      // leichte Welle, damit es nicht wie ein perfekter Kreis aussieht
      final r = radiusM * (1 + 0.18 * math.sin(a * 3));
      final dLat = (r * math.cos(a)) / 111320;
      final dLon = (r * math.sin(a)) /
          (111320 * math.cos(req.startLat * math.pi / 180));
      pts.add(RoutePoint(req.startLat + dLat, req.startLon + dLon));
    }

    double dist = 0;
    for (var i = 1; i < pts.length; i++) {
      dist += distanceMeters(
          pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    }

    return RoutePlan(
      points: pts,
      distanceM: dist,
      durationSec: (dist / 1000 / 60 * 3600).round(),
      title: req.title ?? 'DEMO – folgt keinen Straßen',
      description: 'Testroute ohne Routing-Server - folgt keinen echten '
          'Strassen. Sobald eine Engine hinterlegt ist, kommt hier die '
          'echte Route.',
    );
  }
}

/// Haengt an eine fertige Route echte Stopps aus OpenStreetMap.
///
/// Aus "Tankstelle nach etwa 90 km" wird hier ein konkreter Ort:
/// Die Funktion sucht den Routenpunkt bei 90 km und fragt dort die
/// naechstgelegene Tankstelle ab.
class StopResolver {
  static Future<RoutePlan> attachStops(
    RoutePlan plan,
    List<StopWish> wishes,
  ) async {
    if (wishes.isEmpty || plan.points.length < 2) return plan;

    // kumulierte Distanz je Routenpunkt
    final cum = <double>[0];
    for (var i = 1; i < plan.points.length; i++) {
      cum.add(cum[i - 1] +
          distanceMeters(plan.points[i - 1].lat, plan.points[i - 1].lon,
              plan.points[i].lat, plan.points[i].lon));
    }
    final total = cum.last;

    final pois = <Poi>[];
    for (var w = 0; w < wishes.length; w++) {
      final wish = wishes[w];
      final targetM = (wish.afterKm != null)
          ? (wish.afterKm! * 1000).clamp(0.0, total)
          : total * (w + 1) / (wishes.length + 1);

      var idx = 0;
      for (var i = 0; i < cum.length; i++) {
        if (cum[i] >= targetM) {
          idx = i;
          break;
        }
        idx = i;
      }

      final at = plan.points[idx];
      final found = await PoiService.nearest(
        lat: at.lat,
        lon: at.lon,
        kind: wish.kind,
      );
      if (found != null) {
        pois.add(Poi(
          id: found.id,
          kind: found.kind,
          lat: found.lat,
          lon: found.lon,
          name: found.name,
          note: wish.reason,
          source: found.source,
        ));
      }
    }

    return RoutePlan(
      points: plan.points,
      distanceM: plan.distanceM,
      durationSec: plan.durationSec,
      steps: plan.steps,
      pois: [...plan.pois, ...pois],
      title: plan.title,
      description: plan.description,
    );
  }
}

/// Bewertet eine Route gegen die eigenen Fahrdaten.
///
/// Liefert den Anteil der Route, der ueber Strassen fuehrt, auf denen
/// der Fahrer schon war - und wie stark er dort in Schraeglage lag.
/// Grundlage fuer "prefer_known_good_roads" und fuer Vorschlaege wie
/// "80 % neue Strecke fuer dich".
class RouteScorer {
  static Map<String, double> score(
      RoutePlan plan, Map<String, double> heatmap) {
    if (plan.points.isEmpty || heatmap.isEmpty) {
      return {'knownShare': 0, 'avgKnownLean': 0};
    }
    var known = 0;
    var leanSum = 0.0;
    for (final p in plan.points) {
      final key =
          '${p.lat.toStringAsFixed(3)},${p.lon.toStringAsFixed(3)}';
      final v = heatmap[key];
      if (v != null) {
        known++;
        leanSum += v;
      }
    }
    return {
      'knownShare': known / plan.points.length,
      'avgKnownLean': known > 0 ? leanSum / known : 0,
    };
  }
}

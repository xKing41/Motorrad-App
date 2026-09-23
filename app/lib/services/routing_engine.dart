import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  ROUTING-ENGINES
//
//  Eine Engine kann genau eines: eine Route ueber eine Liste von
//  Wegpunkten berechnen. Wie daraus eine gute Motorradtour wird
//  (Rundtour, Varianten, Bewertung), entscheidet der TourPlanner in
//  route_planner.dart - fuer alle Engines gleich.
//
//  Standard ist Valhalla auf dem Server der FOSSGIS (derselbe Dienst,
//  den openstreetmap.org fuer die Routenplanung nutzt). Kein Schluessel,
//  kein Konto, und Valhalla hat ein eigenes Motorrad-Profil.
// ---------------------------------------------------------------------------

/// Fehler bei der Routenberechnung - mit Text, der dem Fahrer direkt
/// angezeigt werden kann.
class RouteException implements Exception {
  RouteException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum WaypointKind {
  /// Start oder Ziel.
  endpoint,

  /// Hilfspunkt, der nur die Form der Tour bestimmt. Wird auf eine
  /// ordentliche Strasse gelegt, nie in eine Sackgasse.
  shape,

  /// Fester Zwischenstopp (Tankstelle, Aussichtspunkt ...). Wird genau
  /// angefahren.
  stop,
}

class Waypoint {
  const Waypoint(this.point, this.kind, {this.heading});

  Waypoint.at(double lat, double lon, this.kind, {this.heading})
      : point = RoutePoint(lat, lon);

  final RoutePoint point;
  final WaypointKind kind;

  /// Fahrtrichtung in Grad (nur beim Neuberechnen unterwegs): die Route
  /// soll in Fahrtrichtung weitergehen, nicht mit einem Wendemanoever.
  final double? heading;
}

/// Fahrvorlieben, die jede Engine versteht.
class RoutingPrefs {
  const RoutingPrefs({
    this.curviness = Curviness.curvy,
    this.avoidMotorways = true,
    this.avoidTolls = false,
    this.avoidUnpaved = true,
    this.avoid = const [],
  });

  factory RoutingPrefs.of(RouteRequest r) => RoutingPrefs(
        curviness: r.curviness,
        avoidMotorways: r.avoidMotorways,
        avoidTolls: r.avoidTolls,
        avoidUnpaved: r.avoidUnpaved,
      );

  final Curviness curviness;
  final bool avoidMotorways;
  final bool avoidTolls;
  final bool avoidUnpaved;

  /// Punkte auf Strassen, die nicht befahren werden sollen (Sperrung,
  /// Stau). Die Engine meidet die Strasse an dieser Stelle.
  final List<RoutePoint> avoid;

  RoutingPrefs withAvoid(List<RoutePoint> more) => RoutingPrefs(
        curviness: curviness,
        avoidMotorways: avoidMotorways,
        avoidTolls: avoidTolls,
        avoidUnpaved: avoidUnpaved,
        avoid: [...avoid, ...more],
      );
}

/// Rohes Ergebnis einer Engine.
class EngineRoute {
  EngineRoute({
    required this.points,
    required this.distanceM,
    required this.durationSec,
    this.steps = const [],
  });

  final List<RoutePoint> points;
  final double distanceM;
  final int durationSec;
  final List<RouteStep> steps;
}

abstract class RoutingEngine {
  /// Name fuer die Anzeige.
  String get label;

  /// Hoechstzahl an Wegpunkten je Anfrage (inklusive Start und Ziel).
  int get maxWaypoints;

  /// Wie viele Anfragen gleichzeitig laufen duerfen. Oeffentliche
  /// Server sind geteilt - dort bewusst wenig.
  int get parallelRequests;

  /// Route ueber [wps]. Mit [alternates] > 0 und genau zwei Punkten
  /// liefert die Engine, wenn moeglich, zusaetzliche Alternativen.
  /// Das erste Element ist immer die Hauptroute.
  Future<List<EngineRoute>> route(
    List<Waypoint> wps,
    RoutingPrefs prefs, {
    int alternates = 0,
  });
}

const Map<String, String> _headers = {
  'Content-Type': 'application/json',
  'User-Agent': 'Schraeglage/4.9 (Motorrad-App)',
};

// ===========================================================================
//  Valhalla
// ===========================================================================

class ValhallaEngine implements RoutingEngine {
  ValhallaEngine({
    String? baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 45),
    Duration? minInterval,
  })  : baseUrl = normalizeUrl(baseUrl),
        _client = client,
        minInterval = minInterval ??
            (normalizeUrl(baseUrl) == publicUrl
                ? const Duration(milliseconds: 1100)
                : Duration.zero);

  /// Oeffentlicher Server der FOSSGIS e. V.
  static const String publicUrl = 'https://valhalla1.openstreetmap.de';

  final String baseUrl;
  final Duration timeout;
  final http.Client? _client;

  /// Mindestabstand zwischen zwei Anfragen. Der oeffentliche Server ist
  /// ein kostenloses Angebot fuer alle - hoechstens eine Anfrage je
  /// Sekunde, nacheinander statt gleichzeitig.
  final Duration minInterval;
  static DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isPublic => baseUrl == publicUrl;

  @override
  String get label => isPublic
      ? 'Valhalla · FOSSGIS/OpenStreetMap'
      : 'Valhalla · eigener Server';

  @override
  int get maxWaypoints => 20;

  @override
  int get parallelRequests => isPublic ? 1 : 4;

  Future<void> _throttle() async {
    if (minInterval == Duration.zero) return;
    final now = DateTime.now();
    final slot = _nextSlot.isAfter(now) ? _nextSlot : now;
    _nextSlot = slot.add(minInterval);
    final wait = slot.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  static String normalizeUrl(String? url) {
    var u = (url ?? '').trim();
    if (u.isEmpty) return publicUrl;
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/route')) u = u.substring(0, u.length - '/route'.length);
    return u;
  }

  /// Server, die das Motorrad-Profil nicht anbieten - dort gleich mit
  /// dem Auto-Profil fragen, statt jedes Mal erst einen Fehler zu holen.
  static final Set<String> _noMotorcycle = {};

  @override
  Future<List<EngineRoute>> route(
    List<Waypoint> wps,
    RoutingPrefs prefs, {
    int alternates = 0,
  }) async {
    if (wps.length < 2) throw RouteException('Zu wenige Wegpunkte.');
    var costing = _noMotorcycle.contains(baseUrl) ? 'auto' : 'motorcycle';
    try {
      return await _send(buildRequest(wps, prefs,
          alternates: alternates, costing: costing));
    } on ValhallaError catch (e) {
      // Profil unbekannt (124/125): mit dem Auto-Profil weiter. Die
      // Bewertung der Varianten sorgt trotzdem fuer Kurven.
      if (costing == 'motorcycle' && (e.code == 124 || e.code == 125)) {
        _noMotorcycle.add(baseUrl);
        return route(wps, prefs, alternates: alternates);
      }
      // Wegpunkt ohne passende Strasse oder kein Weg: nochmal ohne
      // Strassenklassen-Filter und mit erlaubtem Wenden versuchen.
      if (e.code == 170 || e.code == 171 || e.code == 442) {
        try {
          return await _send(buildRequest(wps, prefs,
              alternates: alternates, relaxed: true, costing: costing));
        } on ValhallaError catch (e2) {
          throw RouteException(e2.userMessage);
        }
      }
      // Motorrad-Profil hat auf oeffentlichen Servern eine Laengengrenze.
      if (e.code == 154 && costing == 'motorcycle') {
        costing = 'auto';
        try {
          return await _send(buildRequest(wps, prefs,
              alternates: alternates, costing: costing));
        } on ValhallaError catch (e2) {
          throw RouteException(e2.userMessage);
        }
      }
      throw RouteException(e.userMessage);
    }
  }

  /// Anfrage fuer die Valhalla-API. Oeffentlich, damit die Tests
  /// pruefen koennen, was wirklich an den Server geht.
  Map<String, dynamic> buildRequest(
    List<Waypoint> wps,
    RoutingPrefs prefs, {
    int alternates = 0,
    bool relaxed = false,
    String costing = 'motorcycle',
  }) {
    final locations = <Map<String, dynamic>>[];
    for (var i = 0; i < wps.length; i++) {
      final w = wps[i];
      final isEnd = i == 0 || i == wps.length - 1;
      final loc = <String, dynamic>{
        'lat': _r6(w.point.lat),
        'lon': _r6(w.point.lon),
      };
      if (w.heading != null) {
        loc['heading'] = (w.heading! % 360).round();
        loc['heading_tolerance'] = 60;
      }
      if (isEnd || w.kind != WaypointKind.shape) {
        loc['type'] = 'break';
      } else if (relaxed) {
        loc['type'] = 'via';
      } else {
        // "through": kein Wenden am Punkt, und er teilt die Route nicht.
        // Zusammen mit dem Filter landet der Punkt auf einer
        // Durchgangsstrasse statt in einer Sackgasse oder Siedlung.
        loc['type'] = 'through';
        loc['search_filter'] = {
          'min_road_class': 'tertiary',
          'max_road_class': prefs.avoidMotorways ? 'primary' : 'motorway',
          'exclude_ramp': true,
          'exclude_closures': true,
        };
      }
      locations.add(loc);
    }

    final opts = <String, dynamic>{
      'use_highways': _useHighways(prefs),
      'use_tolls': prefs.avoidTolls ? 0.0 : 0.5,
      if (prefs.avoidUnpaved) 'exclude_unpaved': true,
    };
    if (costing == 'motorcycle') opts['use_trails'] = _useTrails(prefs);

    return {
      'locations': locations,
      'costing': costing,
      'costing_options': {costing: opts},
      'directions_options': {'units': 'kilometers', 'language': 'de-DE'},
      if (alternates > 0 && wps.length == 2) 'alternates': alternates,
      if (prefs.avoid.isNotEmpty)
        'exclude_locations': [
          for (final a in prefs.avoid.take(maxAvoid))
            {'lat': _r6(a.lat), 'lon': _r6(a.lon)},
        ],
      'id': 'schraeglage',
    };
  }

  /// 0 = Autobahnen meiden, 1 = gerne Autobahn.
  static double _useHighways(RoutingPrefs p) {
    if (p.avoidMotorways) return 0.0;
    return switch (p.curviness) {
      Curviness.direct => 1.0,
      Curviness.balanced => 0.5,
      Curviness.curvy => 0.2,
      Curviness.veryCurvy => 0.0,
    };
  }

  /// Valhalla: Werte gegen 1 meiden grosse Strassen und fuehren ueber
  /// kleinere Landstrassen - genau das, was "kurvig" meistens heisst.
  static double _useTrails(RoutingPrefs p) => switch (p.curviness) {
        Curviness.direct => 0.0,
        Curviness.balanced => 0.2,
        Curviness.curvy => 0.45,
        Curviness.veryCurvy => p.avoidUnpaved ? 0.6 : 0.85,
      };

  static double _r6(double v) => (v * 1e6).round() / 1e6;

  /// Hoechstzahl gemiedener Punkte je Anfrage.
  static const int maxAvoid = 50;

  Future<List<EngineRoute>> _send(Map<String, dynamic> body) async {
    final uri = Uri.parse('$baseUrl/route');
    await _throttle();
    http.Response res;
    try {
      final c = _client;
      final f = c != null
          ? c.post(uri, headers: _headers, body: jsonEncode(body))
          : http.post(uri, headers: _headers, body: jsonEncode(body));
      res = await f.timeout(timeout);
    } on TimeoutException {
      throw RouteException(
          'Der Routing-Server antwortet nicht. Bitte gleich nochmal versuchen.');
    } catch (_) {
      throw RouteException(
          'Routing-Server nicht erreichbar. Internetverbindung prüfen.');
    }

    if (res.statusCode == 200) {
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! Map<String, dynamic>) {
        throw RouteException('Unerwartete Antwort vom Routing-Server.');
      }
      return parseResponse(data);
    }

    int? code;
    String? msg;
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map) {
        code = (j['error_code'] as num?)?.toInt();
        msg = j['error']?.toString();
      }
    } catch (_) {
      // Kein JSON - dann nur mit dem Statuscode weiter.
    }
    throw ValhallaError(res.statusCode, code, msg);
  }

  /// Wertet eine Valhalla-Antwort aus (Hauptroute plus Alternativen).
  static List<EngineRoute> parseResponse(Map<String, dynamic> data) {
    final out = <EngineRoute>[];
    final trip = data['trip'];
    if (trip is Map<String, dynamic>) out.add(_parseTrip(trip));
    final alts = data['alternates'];
    if (alts is List) {
      for (final a in alts) {
        if (a is Map && a['trip'] is Map<String, dynamic>) {
          out.add(_parseTrip(a['trip'] as Map<String, dynamic>));
        }
      }
    }
    out.removeWhere((r) => r.points.length < 2);
    if (out.isEmpty) throw RouteException('Keine Route gefunden.');
    return out;
  }

  static EngineRoute _parseTrip(Map<String, dynamic> trip) {
    final perUnit = trip['units'] == 'miles' ? 1609.344 : 1000.0;
    final pts = <RoutePoint>[];
    final steps = <RouteStep>[];
    for (final leg in (trip['legs'] as List?) ?? const []) {
      if (leg is! Map) continue;
      final shape = decodePolyline((leg['shape'] as String?) ?? '');
      if (shape.isEmpty) continue;
      // Jeder Abschnitt beginnt mit dem Endpunkt des vorigen.
      final offset = pts.isEmpty ? 0 : pts.length - 1;
      pts.addAll(pts.isEmpty ? shape : shape.skip(1));
      for (final m in (leg['maneuvers'] as List?) ?? const []) {
        if (m is! Map) continue;
        final idx = (m['begin_shape_index'] as num?)?.toInt() ?? 0;
        String? str(String k) {
          final v = m[k];
          return v is String && v.trim().isNotEmpty ? v.trim() : null;
        }

        steps.add(RouteStep(
          text: (m['instruction'] ?? '').toString(),
          distanceM: ((m['length'] as num?)?.toDouble() ?? 0) * perUnit,
          pointIndex: offset + idx,
          type: (m['type'] as num?)?.toInt() ?? 0,
          verbal: str('verbal_pre_transition_instruction'),
          alert: str('verbal_transition_alert_instruction'),
        ));
      }
    }
    final summary = trip['summary'];
    final len = summary is Map ? (summary['length'] as num?)?.toDouble() : null;
    final time = summary is Map ? (summary['time'] as num?)?.toDouble() : null;
    return EngineRoute(
      points: pts,
      distanceM: (len != null && len > 0) ? len * perUnit : pathLength(pts),
      durationSec: (time ?? 0).round(),
      steps: steps,
    );
  }
}

/// Fehlerantwort von Valhalla.
class ValhallaError implements Exception {
  ValhallaError(this.status, this.code, this.detail);

  final int status;
  final int? code;
  final String? detail;

  String get userMessage {
    if (status == 429) {
      return 'Der Routing-Server ist gerade ausgelastet. '
          'Bitte einen Moment warten und erneut versuchen.';
    }
    if (status >= 500) {
      return 'Der Routing-Server hat ein Problem (Code $status). '
          'Bitte später erneut versuchen.';
    }
    switch (code) {
      case 154:
        return 'Die Tour ist zu lang für den Routing-Server. '
            'Bitte eine kürzere Länge wählen.';
      case 170:
      case 442:
        return 'Zwischen den Punkten wurde kein befahrbarer Weg gefunden.';
      case 171:
        return 'Für einen Punkt wurde keine befahrbare Straße gefunden.';
    }
    return 'Routing fehlgeschlagen (Code $status'
        '${code != null ? '/$code' : ''}).';
  }

  @override
  String toString() => 'ValhallaError($status, $code, $detail)';
}

// ===========================================================================
//  GraphHopper (optional, mit eigenem Schluessel oder eigenem Server)
// ===========================================================================

class GraphHopperEngine implements RoutingEngine {
  GraphHopperEngine({
    required String baseUrl,
    this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 40),
  })  : baseUrl = _clean(baseUrl),
        _client = client;

  final String baseUrl;
  final String? apiKey;
  final Duration timeout;
  final http.Client? _client;

  bool get _officialApi => baseUrl.contains('graphhopper.com');

  @override
  String get label => _officialApi ? 'GraphHopper' : 'GraphHopper · eigener Server';

  /// Das kostenlose Paket der offiziellen API erlaubt nur 5 Punkte.
  @override
  int get maxWaypoints => _officialApi ? 5 : 30;

  @override
  int get parallelRequests => 2;

  static String _clean(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/route')) u = u.substring(0, u.length - '/route'.length);
    return u;
  }

  @override
  Future<List<EngineRoute>> route(
    List<Waypoint> wps,
    RoutingPrefs prefs, {
    int alternates = 0,
  }) async {
    try {
      return await _send(wps, prefs, alternates, withCurvature: true);
    } on _GhCurvatureMissing {
      // Manche Server kennen den Wert "curvature" nicht - dann eben ohne.
      return _send(wps, prefs, alternates, withCurvature: false);
    }
  }

  Future<List<EngineRoute>> _send(
    List<Waypoint> wps,
    RoutingPrefs prefs,
    int alternates, {
    required bool withCurvature,
  }) async {
    final key = apiKey;
    final uri = Uri.parse(
        '$baseUrl/route${key != null && key.isNotEmpty ? '?key=$key' : ''}');
    final body = <String, dynamic>{
      'profile': 'car',
      'points': [
        for (final w in wps) [w.point.lon, w.point.lat]
      ],
      'points_encoded': false,
      'instructions': true,
      'locale': 'de',
      'ch.disable': true, // Pflicht, sobald ein Custom Model genutzt wird
      'custom_model': customModel(prefs, withCurvature: withCurvature),
    };
    if (alternates > 0 && wps.length == 2) {
      body['algorithm'] = 'alternative_route';
      body['alternative_route.max_paths'] = alternates + 1;
    }

    http.Response res;
    try {
      final c = _client;
      final f = c != null
          ? c.post(uri, headers: _headers, body: jsonEncode(body))
          : http.post(uri, headers: _headers, body: jsonEncode(body));
      res = await f.timeout(timeout);
    } on TimeoutException {
      throw RouteException('Der Routing-Server antwortet nicht.');
    } catch (_) {
      throw RouteException(
          'Routing-Server nicht erreichbar. Internetverbindung prüfen.');
    }

    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode != 200) {
      if (res.statusCode == 400 && withCurvature && text.contains('curvature')) {
        throw _GhCurvatureMissing();
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw RouteException(
            'GraphHopper-Schlüssel wurde nicht akzeptiert (Code ${res.statusCode}).');
      }
      if (res.statusCode == 429) {
        throw RouteException(
            'GraphHopper: Tageskontingent erschöpft oder zu viele Anfragen.');
      }
      throw RouteException('Routing fehlgeschlagen (Code ${res.statusCode}). '
          'Server-Adresse und Schlüssel prüfen.');
    }

    final data = jsonDecode(text);
    final paths = data is Map ? (data['paths'] as List?) ?? const [] : const [];
    final out = <EngineRoute>[];
    for (final p in paths) {
      if (p is! Map) continue;
      final coords = ((p['points'] as Map?)?['coordinates'] as List?) ?? const [];
      final pts = <RoutePoint>[
        for (final c in coords)
          if (c is List && c.length >= 2)
            RoutePoint((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ];
      final steps = <RouteStep>[];
      for (final i in (p['instructions'] as List?) ?? const []) {
        if (i is! Map) continue;
        final text = (i['text'] ?? '').toString();
        steps.add(RouteStep(
          text: text,
          distanceM: (i['distance'] as num?)?.toDouble() ?? 0,
          pointIndex: ((i['interval'] as List?)?.first as num?)?.toInt() ?? 0,
          type: ghSignToType((i['sign'] as num?)?.toInt() ?? 0),
          verbal: text.isEmpty ? null : text,
        ));
      }
      if (pts.length < 2) continue;
      out.add(EngineRoute(
        points: pts,
        distanceM: (p['distance'] as num?)?.toDouble() ?? pathLength(pts),
        durationSec: (((p['time'] as num?)?.toDouble() ?? 0) / 1000).round(),
        steps: steps,
      ));
    }
    if (out.isEmpty) {
      throw RouteException('Keine Route gefunden. Andere Vorgaben versuchen.');
    }
    return out;
  }

  /// GraphHopper-Abbiegezeichen auf die Valhalla-Nummerierung.
  static int ghSignToType(int sign) => switch (sign) {
        -3 => ManeuverType.sharpLeft,
        -2 => ManeuverType.left,
        -1 => ManeuverType.slightLeft,
        1 => ManeuverType.slightRight,
        2 => ManeuverType.right,
        3 => ManeuverType.sharpRight,
        4 => ManeuverType.destination,
        6 => ManeuverType.roundaboutEnter,
        -7 => ManeuverType.stayLeft,
        7 => ManeuverType.stayRight,
        -98 || -8 => ManeuverType.uturnLeft,
        8 => ManeuverType.uturnRight,
        _ => ManeuverType.straight,
      };

  /// Custom Model fuer GraphHopper.
  ///
  /// "curvature" ist Luftlinie / Streckenlaenge eines Abschnitts: nahe 1
  /// = schnurgerade. Prioritaeten duerfen in GraphHopper nicht ueber 1
  /// steigen - kurvig heisst deshalb: gerade Strassen abwerten, nicht
  /// kurvige aufwerten.
  static Map<String, dynamic> customModel(
    RoutingPrefs p, {
    bool withCurvature = true,
  }) {
    final priority = <Map<String, dynamic>>[];
    if (withCurvature) {
      switch (p.curviness) {
        case Curviness.direct:
          break;
        case Curviness.balanced:
          priority.add({'if': 'curvature > 0.95', 'multiply_by': '0.7'});
        case Curviness.curvy:
          priority.add({'if': 'curvature > 0.9', 'multiply_by': '0.45'});
        case Curviness.veryCurvy:
          priority
            ..add({'if': 'curvature > 0.8', 'multiply_by': '0.4'})
            ..add({'if': 'curvature > 0.95', 'multiply_by': '0.5'});
      }
    }
    if (p.curviness == Curviness.curvy || p.curviness == Curviness.veryCurvy) {
      priority.add({'if': 'road_class == TRUNK', 'multiply_by': '0.3'});
    }
    if (p.avoidMotorways || p.curviness == Curviness.veryCurvy) {
      priority.add({'if': 'road_class == MOTORWAY', 'multiply_by': '0.05'});
    }
    if (p.avoidUnpaved) {
      priority.add({'if': 'road_class == TRACK', 'multiply_by': '0.05'});
    }
    // Gemiedene Stellen als kleine Flaechen (etwa 60 x 60 m).
    final features = <Map<String, dynamic>>[];
    for (var i = 0; i < p.avoid.length && i < 30; i++) {
      final a = p.avoid[i];
      const dLat = 0.0003;
      final dLon = 0.0003 / math.max(0.2, math.cos(a.lat * math.pi / 180));
      final ring = [
        [a.lon - dLon, a.lat - dLat],
        [a.lon + dLon, a.lat - dLat],
        [a.lon + dLon, a.lat + dLat],
        [a.lon - dLon, a.lat + dLat],
        [a.lon - dLon, a.lat - dLat],
      ];
      features.add({
        'type': 'Feature',
        'id': 'avoid$i',
        'geometry': {
          'type': 'Polygon',
          'coordinates': [ring],
        },
      });
      priority.add({'if': 'in_avoid$i', 'multiply_by': '0'});
    }
    return {
      'priority': priority,
      'distance_influence': p.curviness == Curviness.direct ? 90 : 15,
      if (features.isNotEmpty)
        'areas': {'type': 'FeatureCollection', 'features': features},
    };
  }
}

class _GhCurvatureMissing implements Exception {}

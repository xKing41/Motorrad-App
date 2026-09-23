import 'dart:async';
import 'dart:math' as math;

import '../models/ride.dart' show heatCellKey;
import '../models/route_plan.dart';
import 'geo.dart';
import 'poi_service.dart';
import 'route_patch.dart';
import 'routing_engine.dart';

export 'routing_engine.dart' show RouteException;

/// Meldet dem Bildschirm, woran der Planer gerade arbeitet.
typedef PlanProgress = void Function(String message);

/// Ortssuche entlang eines Routenstuecks (austauschbar fuer Tests).
/// null = Suche fehlgeschlagen.
typedef PoiSearch = Future<List<Poi>?> Function(
    List<RoutePoint> route, List<PoiKind> kinds, double corridorM);

Future<List<Poi>?> _overpassSearch(
        List<RoutePoint> route, List<PoiKind> kinds, double corridorM) =>
    PoiService.searchAlongRoute(
        route: route, kinds: kinds, corridorM: corridorM);

/// Eine Stelle auf der Route, an der ein Stopp liegen soll.
class StopSlot {
  StopSlot(this.wish, this.targetM, this.loM, this.hiM);

  /// Pause, Aussicht ...: Suche 20 km vor und nach der Stelle.
  factory StopSlot.around(StopWish w, double t, double total) =>
      StopSlot(w, t, _lo(t - 20000, total), math.min(total, t + 20000));

  /// Tanken: lieber frueher als spaeter. Das Fenster reicht weit nach
  /// vorn, damit die Kette der Tankstopps immer einen Anschluss findet.
  factory StopSlot.fuel(StopWish w, double t, double total,
          {double fuelEveryM = 150000}) =>
      StopSlot(w, t, _lo(t - math.max(45000.0, fuelEveryM * 0.5), total),
          math.min(total, t + 5000));

  static double _lo(double v, double total) =>
      math.max(v, math.min(3000.0, total * 0.05));

  final StopWish wish;
  final double targetM;
  final double loM;
  final double hiM;

  PoiKind get kind => wish.kind;

  /// Kommt der Ort fuer diese Stelle in Frage? Etwas Spielraum ueber das
  /// Suchfenster hinaus - die Kosten bestrafen die Entfernung ohnehin.
  bool accepts(StopCandidate k) =>
      k.poi.kind == kind &&
      k.alongM >= loM - 30000 &&
      k.alongM <= hiM + 30000;

  @override
  String toString() => 'StopSlot(${kind.name} @ ${(targetM / 1000).round()} km)';
}

/// Abschnitt der Route, in dem nach Orten gesucht wird.
class StopSection {
  StopSection(this.loM, this.hiM, this.kinds);
  final double loM;
  double hiM;
  final Set<PoiKind> kinds;
}

/// Gefundener Ort mit seiner Lage zur Route.
class StopCandidate {
  StopCandidate(this.poi, this.alongM, this.offM);
  final Poi poi;

  /// Position entlang der Route (m ab Start).
  final double alongM;

  /// Seitlicher Abstand zur Route in m.
  final double offM;
}

// ---------------------------------------------------------------------------
//  TOURENPLANER
//
//  Vorher: Eine Anfrage an die Engine, das Ergebnis wurde ungeprueft
//  uebernommen - und ohne Server gab es nur einen gemalten Kreis um den
//  Standort, der keiner Strasse folgte.
//
//  Jetzt:
//   1. Rundtour-Form: Der Start liegt AUF der Schleife (nicht in ihrer
//      Mitte). Hilfspunkte legen die Form fest, die Engine verbindet sie
//      ueber echte Strassen - mit Motorrad-Profil.
//   2. Mehrere Varianten in verschiedene Richtungen.
//   3. Jede Variante wird bewertet: Kurvigkeit, Laenge, doppelt
//      gefahrene Abschnitte, auf Wunsch eigene Lieblingsstrecken.
//   4. Stichstrassen ("hin und auf demselben Weg zurueck") werden
//      herausgeschnitten.
//   5. Die Laenge wird nachgeregelt, wenn sie zu weit daneben liegt.
//   6. Zwischenstopps werden als echte Wegpunkte eingebaut - die Route
//      fuehrt wirklich an der Tankstelle vorbei.
// ---------------------------------------------------------------------------

/// Bewertung einer berechneten Route.
class RouteQuality {
  const RouteQuality({
    required this.curvature,
    required this.overlap,
    required this.lengthM,
    required this.lengthError,
    required this.knownShare,
    required this.score,
  });

  final CurvatureStats curvature;
  final double overlap;
  final double lengthM;

  /// Rundtour: relative Abweichung von der Wunschlaenge.
  /// A nach B: Umweg ueber das erlaubte Mass hinaus.
  final double lengthError;
  final double knownShare;
  final double score;

  RouteStats toStats() => RouteStats(
        curvIndex: curvature.index,
        curvLabel: curvature.label,
        bendsPerKm: curvature.bendsPerKm,
        overlapShare: overlap,
        knownShare: knownShare,
        score: score,
      );
}

/// Die Bewertungsregeln - getrennt vom Netz, damit sie testbar sind.
class RouteScoring {
  /// Wie stark die Kurvigkeit zaehlt, je nach Wunsch des Fahrers.
  static double curvWeight(Curviness c) => switch (c) {
        Curviness.direct => 0.0,
        Curviness.balanced => 0.6,
        Curviness.curvy => 1.0,
        Curviness.veryCurvy => 1.4,
      };

  static RouteQuality evaluate(
    List<RoutePoint> pts, {
    required Curviness curviness,
    required double lengthError,
    bool roundTrip = true,
    Map<String, double>? heatmap,
    bool preferKnown = false,
  }) {
    final curv = curvatureOf(pts);
    final overlap = overlapShare(
      pts,
      ignoreStartM: roundTrip ? 800 : 300,
      ignoreEndM: roundTrip ? 800 : 300,
    );
    final known =
        (heatmap == null || heatmap.isEmpty) ? 0.0 : knownShare(pts, heatmap);

    var score = 100.0;
    score += curvWeight(curviness) * 40 * math.min(curv.index, 1.5);
    // Bis 8 % Abweichung ist frei, danach wird es teuer.
    score -= 120 * math.max(0.0, lengthError - 0.08);
    // Doppelt gefahrene Strecke ist der aergerlichste Planungsfehler.
    score -= 150 * overlap;
    if (preferKnown) score += 25 * known;

    return RouteQuality(
      curvature: curv,
      overlap: overlap,
      lengthM: pathLength(pts),
      lengthError: lengthError,
      knownShare: known,
      score: score,
    );
  }

  /// Anteil der Route auf Strassen, die in den eigenen Fahrten vorkommen.
  static double knownShare(List<RoutePoint> pts, Map<String, double> heatmap) {
    final r = resample(pts, 50);
    if (r.isEmpty) return 0;
    var hit = 0;
    for (final p in r) {
      if (heatmap.containsKey(heatCellKey(p.lat, p.lon))) hit++;
    }
    return hit / r.length;
  }

  /// Wie aehnlich sind sich zwei Routen? 0 = nichts gemeinsam, 1 = gleich.
  static double similarity(List<RoutePoint> a, List<RoutePoint> b) {
    final sa = _signature(a), sb = _signature(b);
    if (sa.isEmpty || sb.isEmpty) return 0;
    final inter = sa.intersection(sb).length;
    return inter / (sa.length + sb.length - inter);
  }

  static Set<String> _signature(List<RoutePoint> pts) => {
        for (final p in resample(pts, 100))
          '${(p.lat * 400).round()}:${(p.lon * 250).round()}',
      };
}

/// Form einer Rundtour: Hilfspunkte auf einem Kreis, der durch den
/// Start geht.
class LoopShape {
  LoopShape({
    required this.bearing,
    required this.clockwise,
    required this.angleJitter,
    required this.radiusJitter,
  });

  factory LoopShape.random(
    int k,
    double bearing,
    bool clockwise,
    math.Random rnd,
  ) {
    final step = 360 / (k + 1);
    return LoopShape(
      bearing: bearing % 360,
      clockwise: clockwise,
      angleJitter:
          List.generate(k, (_) => (rnd.nextDouble() * 2 - 1) * step * 0.22),
      radiusJitter:
          List.generate(k, (_) => 1 + (rnd.nextDouble() * 2 - 1) * 0.15),
    );
  }

  /// Richtung vom Start zum Kreismittelpunkt.
  final double bearing;
  final bool clockwise;
  final List<double> angleJitter;
  final List<double> radiusJitter;

  int get k => angleJitter.length;

  /// Hilfspunkte fuer einen Kreis mit [radius]. Liegt [via] in
  /// Reichweite, ersetzt er den naechstgelegenen Hilfspunkt - die Tour
  /// fuehrt dann wirklich dort vorbei.
  List<RoutePoint> points(RoutePoint start, double radius, {RoutePoint? via}) {
    final center = destinationPoint(start, bearing, radius);
    final startAngle = (bearing + 180) % 360;
    final step = 360 / (k + 1) * (clockwise ? 1 : -1);
    final pts = <RoutePoint>[
      for (var j = 1; j <= k; j++)
        destinationPoint(center, startAngle + j * step + angleJitter[j - 1],
            radius * radiusJitter[j - 1]),
    ];
    if (via != null && dist(start, via) <= 2.2 * radius) {
      var best = 0;
      for (var j = 1; j < pts.length; j++) {
        if (dist(pts[j], via) < dist(pts[best], via)) best = j;
      }
      pts[best] = via;
    }
    return pts;
  }

  /// Umfang des Hilfspunkt-Vielecks je Meter Radius.
  double perimeterFactor(RoutePoint start, {RoutePoint? via, double radius = 10000}) {
    final pts = [start, ...points(start, radius, via: via), start];
    return pathLength(pts) / radius;
  }
}

/// Eine berechnete und bewertete Variante.
class _Candidate {
  _Candidate({
    required this.waypoints,
    required this.route,
    required this.quality,
    this.shape,
    this.radius = 0,
    this.pois = const [],
    this.notes = const [],
  });

  final List<Waypoint> waypoints;
  final EngineRoute route;
  final RouteQuality quality;
  final LoopShape? shape;
  final double radius;
  final List<Poi> pois;
  final List<String> notes;

  _Candidate copyWith({
    List<Waypoint>? waypoints,
    EngineRoute? route,
    RouteQuality? quality,
    double? radius,
    List<Poi>? pois,
    List<String>? notes,
  }) =>
      _Candidate(
        waypoints: waypoints ?? this.waypoints,
        route: route ?? this.route,
        quality: quality ?? this.quality,
        shape: shape,
        radius: radius ?? this.radius,
        pois: pois ?? this.pois,
        notes: notes ?? this.notes,
      );
}

class TourPlanner {
  TourPlanner(
    this.engine, {
    this.heatmap,
    math.Random? random,
    this.maxVariants = 3,
    PoiSearch? poiSearch,
  })  : _rnd = random ?? math.Random(),
        _poiSearch = poiSearch ?? _overpassSearch;

  final PoiSearch _poiSearch;

  final RoutingEngine engine;

  /// Eigene Strecken (Rasterzellen), fuer "bewaehrte Strecken bevorzugen".
  final Map<String, double>? heatmap;

  /// Wie viele Varianten der Fahrer hoechstens zur Auswahl bekommt.
  final int maxVariants;

  final math.Random _rnd;

  Future<RoutePlan> plan(RouteRequest req, {PlanProgress? onProgress}) async {
    void say(String m) => onProgress?.call(m);

    var cands = req.roundTrip
        ? await _roundTrip(req, say)
        : await _aToB(req, say);

    cands.sort((a, b) => b.quality.score.compareTo(a.quality.score));
    cands = _distinct(cands);
    // Stopps kosten je Variante eine Kartenabfrage und eine Route -
    // dann lieber weniger Varianten.
    // Lange Touren haben viele Stopps - dann nur fuer den besten
    // Vorschlag suchen, sonst dauert es ewig.
    final longTrip = cands.isNotEmpty &&
        pathLength(cands.first.route.points) > 400000;
    final keep = req.stops.isEmpty
        ? maxVariants
        : math.min(longTrip ? 1 : 2, maxVariants);
    cands = cands.take(keep).toList();

    if (req.stops.isNotEmpty) {
      final withStops = <_Candidate>[];
      for (var i = 0; i < cands.length; i++) {
        final prefix = cands.length > 1 ? 'Variante ${i + 1}: ' : '';
        withStops.add(
            await _attachStops(cands[i], req, (m) => say('$prefix$m')));
      }
      cands = withStops
        ..sort((a, b) => b.quality.score.compareTo(a.quality.score));
    }

    final plans = [for (final c in cands) _toPlan(c, req)];
    return plans.first.copyWith(alternatives: plans.skip(1).toList());
  }

  // -------------------------------------------------------------------------
  //  Rundtour
  // -------------------------------------------------------------------------

  static double roadFactor(Curviness c) => switch (c) {
        Curviness.direct => 1.25,
        Curviness.balanced => 1.30,
        Curviness.curvy => 1.38,
        Curviness.veryCurvy => 1.45,
      };

  /// Anzahl Hilfspunkte je nach Tourlaenge.
  static int shapePoints(double targetM) =>
      targetM <= 80000 ? 3 : (targetM <= 220000 ? 4 : 5);

  Future<List<_Candidate>> _roundTrip(
      RouteRequest req, void Function(String) say) async {
    final start = RoutePoint(req.startLat, req.startLon);
    final target = req.distanceKm * 1000;
    final via = req.hasVia ? RoutePoint(req.viaLat!, req.viaLon!) : null;

    var k = shapePoints(target);
    k = math.min(k, math.max(2, engine.maxWaypoints - 2 - req.stops.length));

    double? fixedBearing = via != null ? bearingDeg(start, via) : null;
    fixedBearing ??= req.direction.degrees;
    final base = fixedBearing ?? _rnd.nextDouble() * 360;

    const n = 4;
    final shapes = <LoopShape>[];
    for (var i = 0; i < n; i++) {
      final spread = fixedBearing != null
          ? const [0.0, -35.0, 35.0, 0.0][i] + (_rnd.nextDouble() * 2 - 1) * 8
          : i * 90.0 + (_rnd.nextDouble() * 2 - 1) * 15;
      shapes.add(LoopShape.random(k, base + spread, i.isEven, _rnd));
    }

    final factor = roadFactor(req.curviness);
    final maxRadius = math.max(1500.0, target / (2 * math.pi));
    double radiusFor(LoopShape s) {
      final r = target / (factor * s.perimeterFactor(start, via: via));
      return r.clamp(1500.0, maxRadius);
    }

    var done = 0;
    final results = await _pool<_Candidate>(
      [
        for (final s in shapes)
          () async {
            final c = await _routeLoop(req, start, s, radiusFor(s), via);
            done++;
            say('Varianten werden berechnet ($done/${shapes.length}) ...');
            return c;
          },
      ],
      engine.parallelRequests,
    );
    final cands = results.whereType<_Candidate>().toList();
    if (cands.isEmpty) throw _lastError ?? RouteException('Keine Route gefunden.');

    // Laenge nachregeln: Die Strassen machen mal mehr, mal weniger Umweg
    // als geschaetzt. Die beiden besten Varianten bekommen einen zweiten
    // Versuch mit angepasstem Radius.
    cands.sort((a, b) => b.quality.score.compareTo(a.quality.score));
    final fix = cands
        .take(2)
        .where((c) => c.quality.lengthError > 0.12 && c.shape != null)
        .toList();
    if (fix.isNotEmpty) {
      say('Länge wird angepasst ...');
      final better = await _pool<_Candidate>(
        [
          for (final c in fix)
            () {
              final ratio = (target / c.quality.lengthM).clamp(0.55, 1.8);
              return _routeLoop(req, start, c.shape!, c.radius * ratio, via);
            },
        ],
        engine.parallelRequests,
      );
      for (var i = 0; i < fix.length; i++) {
        final b = better[i];
        if (b != null && b.quality.score > fix[i].quality.score) {
          cands[cands.indexOf(fix[i])] = b;
        }
      }
    }

    if (via != null && dist(start, via) > 2.2 * radiusFor(shapes.first)) {
      return [
        for (final c in cands)
          c.copyWith(notes: [
            ...c.notes,
            'Der gewünschte Ort liegt außerhalb der Tourlänge - '
                'die Tour führt nur in seine Richtung.',
          ]),
      ];
    }
    return cands;
  }

  Future<_Candidate> _routeLoop(
    RouteRequest req,
    RoutePoint start,
    LoopShape shape,
    double radius,
    RoutePoint? via,
  ) async {
    final wps = <Waypoint>[
      Waypoint(start, WaypointKind.endpoint),
      for (final p in shape.points(start, radius, via: via))
        Waypoint(p, WaypointKind.shape),
      Waypoint(start, WaypointKind.endpoint),
    ];
    final routes = await engine.route(wps, RoutingPrefs.of(req));
    final r = cleanRoute(routes.first);
    final target = req.distanceKm * 1000;
    final len = pathLength(r.points);
    return _Candidate(
      waypoints: wps,
      route: r,
      shape: shape,
      radius: radius,
      quality: RouteScoring.evaluate(
        r.points,
        curviness: req.curviness,
        lengthError: target > 0 ? (len - target).abs() / target : 0,
        roundTrip: true,
        heatmap: heatmap,
        preferKnown: req.preferKnownGoodRoads,
      ),
    );
  }

  // -------------------------------------------------------------------------
  //  Von A nach B
  // -------------------------------------------------------------------------

  /// Ab dieser Luftlinie wird in Etappen gerechnet.
  static const double longTripM = 350000;

  /// Etappenpunkte auf der Luftlinie, hoechstens 300 km auseinander.
  static List<RoutePoint> legPoints(RoutePoint a, RoutePoint b) {
    final d = dist(a, b);
    final n = (d / 300000).ceil();
    final brg = bearingDeg(a, b);
    return [
      a,
      for (var i = 1; i < n; i++) destinationPoint(a, brg, d * i / n),
      b,
    ];
  }

  Future<EngineRoute> _routeInLegs(RoutePoint a, RoutePoint b,
      RoutingPrefs prefs, void Function(String) say) async {
    final stops = legPoints(a, b);
    final parts = <EngineRoute>[];
    for (var i = 0; i < stops.length - 1; i++) {
      say('Etappe ${i + 1}/${stops.length - 1} wird berechnet ...');
      parts.add((await engine.route([
        Waypoint(stops[i], WaypointKind.endpoint),
        Waypoint(stops[i + 1], WaypointKind.endpoint),
      ], prefs))
          .first);
    }
    return cleanRoute(joinRoutes(parts));
  }

  /// Erlaubter Umweg gegenueber der kuerzesten gefundenen Route.
  static double detourBudget(Curviness c) => switch (c) {
        Curviness.direct => 0.05,
        Curviness.balanced => 0.2,
        Curviness.curvy => 0.4,
        Curviness.veryCurvy => 0.7,
      };

  Future<List<_Candidate>> _aToB(
      RouteRequest req, void Function(String) say) async {
    if (!req.hasEnd) {
      throw RouteException('Für eine Tour ohne Rückweg fehlt das Ziel.');
    }
    final a = RoutePoint(req.startLat, req.startLon);
    final b = RoutePoint(req.endLat!, req.endLon!);
    final direct = dist(a, b);
    if (direct < 300) {
      throw RouteException('Start und Ziel liegen zu nah beieinander.');
    }
    final prefs = RoutingPrefs.of(req);
    final via = req.hasVia ? RoutePoint(req.viaLat!, req.viaLon!) : null;

    // Sehr lange Strecken rechnet der oeffentliche Server nicht am Stueck
    // ("zu lang"). Dann in Etappen rechnen und zusammensetzen.
    if (via == null && direct > longTripM) {
      final r = await _routeInLegs(a, b, prefs, say);
      return [
        _Candidate(
          waypoints: [
            Waypoint(a, WaypointKind.endpoint),
            Waypoint(b, WaypointKind.endpoint),
          ],
          route: r,
          quality: RouteScoring.evaluate(
            r.points,
            curviness: req.curviness,
            lengthError: 0,
            roundTrip: false,
            heatmap: heatmap,
            preferKnown: req.preferKnownGoodRoads,
          ),
        ),
      ];
    }

    final jobs = <List<Waypoint>>[];
    if (via != null) {
      jobs.add([
        Waypoint(a, WaypointKind.endpoint),
        Waypoint(via, WaypointKind.shape),
        Waypoint(b, WaypointKind.endpoint),
      ]);
    } else {
      jobs.add([Waypoint(a, WaypointKind.endpoint), Waypoint(b, WaypointKind.endpoint)]);
      // Kurvige Umwege links und rechts der direkten Linie anbieten.
      if (req.curviness != Curviness.direct && direct > 8000) {
        final brg = bearingDeg(a, b);
        final mid = destinationPoint(a, brg, direct / 2);
        final fracs = switch (req.curviness) {
          Curviness.balanced => const [0.12, -0.12],
          Curviness.curvy => const [0.18, -0.18],
          _ => const [0.22, -0.22, 0.35],
        };
        for (final f in fracs) {
          final off = math.min(f.abs() * direct, 30000.0);
          final w = destinationPoint(mid, brg + (f > 0 ? 90 : -90), off);
          jobs.add([
            Waypoint(a, WaypointKind.endpoint),
            Waypoint(w, WaypointKind.shape),
            Waypoint(b, WaypointKind.endpoint),
          ]);
        }
      }
    }

    var done = 0;
    final results = await _pool<List<(List<Waypoint>, EngineRoute)>>(
      [
        for (var i = 0; i < jobs.length; i++)
          () async {
            final rs = await engine.route(jobs[i], prefs,
                alternates: jobs[i].length == 2 ? 2 : 0);
            done++;
            say('Varianten werden berechnet ($done/${jobs.length}) ...');
            return [for (final r in rs) (jobs[i], cleanRoute(r))];
          },
      ],
      engine.parallelRequests,
    );
    final routes = results.whereType<List<(List<Waypoint>, EngineRoute)>>()
        .expand((l) => l)
        .toList();
    if (routes.isEmpty) throw _lastError ?? RouteException('Keine Route gefunden.');

    final ref = routes.map((r) => pathLength(r.$2.points)).reduce(math.min);
    final budget = detourBudget(req.curviness);
    return [
      for (final (wps, r) in routes)
        _Candidate(
          waypoints: wps,
          route: r,
          quality: RouteScoring.evaluate(
            r.points,
            curviness: req.curviness,
            lengthError:
                math.max(0.0, pathLength(r.points) / ref - 1 - budget),
            roundTrip: false,
            heatmap: heatmap,
            preferKnown: req.preferKnownGoodRoads,
          ),
        ),
    ];
  }

  // -------------------------------------------------------------------------
  //  Zwischenstopps
  // -------------------------------------------------------------------------

  Future<_Candidate> _attachStops(
      _Candidate c, RouteRequest req, void Function(String) say) async {
    final pts = c.route.points;
    final cum = cumulativeDistances(pts);
    final slots = planSlots(req.stops, cum.last,
        fuelEveryKm: req.fuelEveryKm, breakEveryKm: req.breakEveryKm);
    if (slots.isEmpty) return c;

    // Gesucht wird nur in Abschnitten um die Stellen, an denen Stopps
    // liegen sollen. Eine Suche entlang der GANZEN Route ist fuer den
    // kostenlosen Kartendienst zu gross (er bricht ab).
    final cands = <String, StopCandidate>{};
    var sections = 0, failed = 0;
    Future<void> searchPass(List<StopSlot> open, double widen) async {
      final secs = mergeSections(open, cum.last, widenM: widen);
      for (var i = 0; i < secs.length; i++) {
        final s = secs[i];
        say('Zwischenstopps werden gesucht (${i + 1}/${secs.length}) ...');
        sections++;
        final res = await _poiSearch(
            subPath(pts, cum, s.loM, s.hiM), s.kinds.toList(), stopCorridorM);
        if (res == null) {
          failed++;
          continue;
        }
        final from = math.max(0, indexAtOrAfter(cum, s.loM) - 1);
        final to = indexAtOrAfter(cum, s.hiM);
        for (final p in res) {
          if (cands.containsKey(p.id)) continue;
          final hit = projectOnPolyline(
              RoutePoint(p.lat, p.lon), pts, cum, from: from, to: to);
          if (hit == null || hit.distanceM > stopCorridorM) continue;
          cands[p.id] = StopCandidate(p, hit.alongM, hit.distanceM);
        }
      }
    }

    await searchPass(slots, 0);
    // Wo nichts Passendes lag: einmal mit groesserem Fenster nachsuchen.
    final missing = [
      for (final s in slots)
        if (!cands.values.any((k) => s.accepts(k))) s
    ];
    if (missing.isNotEmpty && failed < sections) {
      await searchPass(missing, 30000);
    }

    if (sections > 0 && failed == sections) {
      return c.copyWith(notes: [
        ...c.notes,
        'Zwischenstopps konnten nicht gesucht werden '
            '(Kartendienst nicht erreichbar).',
      ]);
    }

    final notes = <String>[...c.notes];
    if (failed > 0) {
      notes.add('Der Kartendienst war teilweise überlastet - '
          'einzelne Abschnitte ohne Stopps.');
    }
    final chosen = chooseStops(slots, cands.values.toList(),
        fuelEveryM: req.fuelEveryKm * 1000, totalM: cum.last);
    for (final k in PoiKind.values) {
      final want = slots.where((s) => s.kind == k).length;
      final got = chosen.where((e) => e.$1.kind == k).length;
      if (want > 0 && got == 0) {
        notes.add('Keine ${k.label} nah an der Route gefunden.');
      } else if (got < want && k != PoiKind.fuel) {
        notes.add('${k.label}: $got von $want gewünschten Stopps gefunden.');
      }
    }
    final gaps = fuelGaps(chosen, cum.last,
        fuelEveryM: req.fuelEveryKm * 1000,
        wanted: slots.any((s) => s.kind == PoiKind.fuel));
    if (gaps > 0) {
      notes.add('Achtung: $gaps Abschnitt${gaps > 1 ? 'e' : ''} länger als '
          '${req.fuelEveryKm.round()} km ohne gefundene Tankstelle.');
    }
    if (chosen.isEmpty) return c.copyWith(notes: notes);

    // Stopps als echte Wegpunkte einbauen und die Route neu berechnen -
    // in Stuecken, damit auch lange Touren mit vielen Stopps gehen.
    final stops = chosen.map((e) => e.$1).toList();
    final wps = mergeWaypoints(c.waypoints, chosen, pts);
    final chunks = chunkWaypoints(wps, pts, cum,
        maxCount: math.max(2, engine.maxWaypoints));
    final prefs = RoutingPrefs.of(req);
    final parts = <EngineRoute>[];
    var chunkFails = 0;
    for (var i = 0; i < chunks.length; i++) {
      final ch = chunks[i];
      say(chunks.length > 1
          ? 'Route über die Stopps (${i + 1}/${chunks.length}) ...'
          : 'Route über die Stopps wird berechnet ...');
      try {
        final r = await engine.route([for (final w in ch) w.$1], prefs);
        parts.add(r.first);
      } on RouteException {
        chunkFails++;
        parts.add(sliceRoute(c.route, ch.first.$2, ch.last.$2, cum: cum));
      }
    }
    if (chunkFails == chunks.length) {
      notes.add('Die Route über die Stopps ließ sich nicht berechnen - '
          'die Stopps sind nur markiert.');
      return c.copyWith(pois: stops, notes: notes);
    }
    if (chunkFails > 0) {
      notes.add('Einzelne Stopps sind nur markiert (Route dorthin '
          'nicht berechenbar).');
    }
    final r = cleanRoute(joinRoutes(parts),
        keep: [for (final p in stops) RoutePoint(p.lat, p.lon)]);
    final len = pathLength(r.points);
    final err = req.roundTrip
        ? (len - req.distanceKm * 1000).abs() / (req.distanceKm * 1000)
        : c.quality.lengthError;
    return c.copyWith(
      waypoints: [for (final w in wps) w.$1],
      route: r,
      pois: stops,
      notes: notes,
      quality: RouteScoring.evaluate(
        r.points,
        curviness: req.curviness,
        lengthError: err,
        roundTrip: req.roundTrip,
        heatmap: heatmap,
        preferKnown: req.preferKnownGoodRoads,
      ),
    );
  }

  /// Wo auf der Route (Meter ab Start) ein einzelner Stopp liegen soll:
  /// nach der gewuenschten Kilometerzahl, sonst gleichmaessig verteilt.
  static double stopTarget(StopWish wish, int index, int count, double total) =>
      wish.afterKm != null
          ? math.min(wish.afterKm! * 1000, total * 0.95)
          : total * (index + 1) / (count + 1);

  /// Suchstreifen links und rechts der Route fuer Zwischenstopps.
  static const double stopCorridorM = 1500;

  /// Hoechstzahl Stopps je Tour.
  static const int maxStops = 40;

  /// Macht aus den Stopp-Wuenschen konkrete Stellen auf der Route.
  ///
  ///  * Tanken: spaetestens alle [fuelEveryKm] - auf 3000 km also nicht
  ///    eine Tankstelle, sondern zwanzig. Auch wenn die KI nur eine
  ///    geplant hat, wird aufgefuellt: ein leerer Tank ist kein
  ///    Komfortproblem.
  ///  * Pausen (Rastplatz, Einkehr, Wasser): alle [breakEveryKm]. Sind
  ///    Rastplatz UND Einkehr gewuenscht, wechseln sie sich ab - nicht
  ///    zwei Pausen direkt hintereinander.
  ///  * Aussichtspunkte: gleichmaessig verteilt, hoechstens acht.
  ///  * Werkstatt: eine.
  static List<StopSlot> planSlots(
    List<StopWish> wishes,
    double totalM, {
    double fuelEveryKm = 150,
    double breakEveryKm = 100,
  }) {
    if (wishes.isEmpty || totalM < 2000) return const [];
    final slots = <StopSlot>[];
    final fuelM = math.max(30.0, fuelEveryKm) * 1000;
    final breakM = math.max(20.0, breakEveryKm) * 1000;

    // Einzelne, fest geplante Stopps (z. B. von der KI).
    final single = wishes.where((w) => !w.repeat).toList();
    for (var i = 0; i < single.length; i++) {
      slots.add(StopSlot.around(
          single[i], stopTarget(single[i], i, single.length, totalM), totalM));
    }

    final repeat = {for (final w in wishes.where((w) => w.repeat)) w.kind: w};
    // Pausen: feste Abstaende, nicht kurz vor dem Ziel.
    List<double> every(double step) {
      final out = <double>[];
      for (var t = step; t < totalM - 0.4 * step; t += step) {
        out.add(t);
      }
      if (out.isEmpty) out.add(totalM / 2);
      return out;
    }

    final rest = repeat[PoiKind.rest], food = repeat[PoiKind.food];
    if (rest != null && food != null) {
      final pos = every(breakM);
      for (var k = 0; k < pos.length; k++) {
        // Jede zweite Pause ist eine Einkehr - auf kurzen Touren (eine
        // einzige Pause) gewinnt die Einkehr.
        final w = (k.isOdd || pos.length == 1) ? food : rest;
        slots.add(StopSlot.around(w, pos[k], totalM));
      }
    } else if (rest != null) {
      for (final t in every(breakM)) {
        slots.add(StopSlot.around(rest, t, totalM));
      }
    } else if (food != null) {
      for (final t in every(math.max(breakM, 150000))) {
        slots.add(StopSlot.around(food, t, totalM));
      }
    }
    final water = repeat[PoiKind.water];
    if (water != null) {
      for (final t in every(breakM)) {
        slots.add(StopSlot.around(water, t, totalM));
      }
    }
    final view = repeat[PoiKind.viewpoint];
    if (view != null) {
      final n = (totalM / 70000).round().clamp(1, 8);
      for (var i = 1; i <= n; i++) {
        slots.add(StopSlot.around(view, totalM * i / (n + 1), totalM));
      }
    }
    final shop = repeat[PoiKind.workshop];
    if (shop != null) slots.add(StopSlot.around(shop, totalM / 2, totalM));

    // Tanken: Luecken zwischen den geplanten Tankstopps auffuellen.
    final fuelWish = repeat[PoiKind.fuel] ??
        single.where((w) => w.kind == PoiKind.fuel).firstOrNull;
    if (fuelWish != null) {
      final fixed = slots
          .where((s) => s.kind == PoiKind.fuel)
          .map((s) => s.targetM)
          .toList()
        ..sort();
      final fill = <double>[];
      var last = 0.0;
      for (final next in [...fixed, totalM]) {
        while (next - last > fuelM) {
          last += fuelM;
          fill.add(last);
        }
        last = next;
      }
      if (fill.isEmpty && fixed.isEmpty) fill.add(totalM / 2);
      final w = StopWish(
          kind: PoiKind.fuel, reason: fuelWish.reason, repeat: true);
      for (final t in fill) {
        slots.add(StopSlot.fuel(w, t, totalM, fuelEveryM: fuelM));
      }
    }

    slots.sort((a, b) => a.targetM.compareTo(b.targetM));
    if (slots.length <= maxStops) return slots;
    // Zu viele: Tanken zuerst, dann Pausen, Aussicht zuletzt.
    int rank(PoiKind k) => switch (k) {
          PoiKind.fuel => 0,
          PoiKind.food => 1,
          PoiKind.rest => 2,
          PoiKind.water => 3,
          PoiKind.workshop => 4,
          PoiKind.viewpoint => 5,
        };
    final keep = [...slots]..sort((a, b) => rank(a.kind).compareTo(rank(b.kind)));
    return keep.take(maxStops).toList()
      ..sort((a, b) => a.targetM.compareTo(b.targetM));
  }

  /// Fasst die Suchfenster benachbarter Stopps zu Abschnitten zusammen -
  /// eine Anfrage je Abschnitt statt je Stopp.
  static List<StopSection> mergeSections(
    List<StopSlot> slots,
    double totalM, {
    double widenM = 0,
    double maxSpanM = 120000,
  }) {
    final sorted = [...slots]..sort((a, b) => a.loM.compareTo(b.loM));
    final out = <StopSection>[];
    for (final s in sorted) {
      final lo = math.max(0.0, s.loM - widenM);
      final hi = math.min(totalM, s.hiM + widenM);
      final cur = out.isEmpty ? null : out.last;
      if (cur != null && lo <= cur.hiM + 5000 && hi - cur.loM <= maxSpanM) {
        cur.hiM = math.max(cur.hiM, hi);
        cur.kinds.add(s.kind);
      } else {
        out.add(StopSection(lo, hi, {s.kind}));
      }
    }
    return out;
  }

  /// Waehlt zu jeder Stopp-Stelle den passendsten Ort.
  ///
  /// Kriterien: nah an der gewuenschten Stelle, nah an der Strasse und
  /// ein "guter" Ort (benannter Aussichtspunkt statt Gipfel im Wald).
  /// Beim Tanken zaehlt die Reichweite: der naechste Tankstopp liegt
  /// hoechstens [fuelEveryM] hinter dem vorigen, wenn es irgend geht -
  /// und "zu spaet" wiegt doppelt, der Tank wird nicht voller.
  ///
  /// Rueckgabe: (Ort, Position entlang der Route in m), nach Position
  /// sortiert. Stellen ohne passenden Ort fehlen.
  static List<(Poi, double)> chooseStops(
    List<StopSlot> slots,
    List<StopCandidate> cands, {
    double fuelEveryM = 150000,
    double? totalM,
  }) {
    final total = totalM ??
        slots.fold<double>(0, (m, s) => math.max(m, s.hiM));
    final chosen = <(Poi, double)>[];
    final used = <String>{};

    StopCandidate? best(Iterable<StopCandidate> pool, double target,
        {bool lateTwice = false}) {
      StopCandidate? b;
      var bestCost = double.infinity;
      for (final k in pool) {
        if (used.contains(k.poi.id)) continue;
        var off = (k.alongM - target) / 1000;
        if (lateTwice && off > 0) off *= 2;
        // Kosten in "Kilometern Umweg": 1 Punkt Qualitaet ist 3 km wert.
        final cost =
            off.abs() + 3 * k.offM / 1000 - 3 * PoiService.stopQuality(k.poi);
        if (cost < bestCost) {
          bestCost = cost;
          b = k;
        }
      }
      return b;
    }

    void take(StopCandidate k, StopWish w) {
      used.add(k.poi.id);
      chosen.add((k.poi.copyWith(note: w.reason, source: 'stop'), k.alongM));
    }

    // Tank-Kette: von Tankstopp zu Tankstopp, nie weiter als die
    // Reichweite, wenn es irgend geht.
    final fillFuel = slots
        .where((s) => s.kind == PoiKind.fuel && s.wish.repeat)
        .toList();
    final chainFuel = fillFuel.isNotEmpty && total > fuelEveryM;

    for (final s in slots) {
      if (chainFuel && s.kind == PoiKind.fuel && s.wish.repeat) continue;
      final k = best(cands.where(s.accepts), s.targetM,
          lateTwice: s.kind == PoiKind.fuel);
      if (k != null) take(k, s.wish);
    }

    if (chainFuel) {
      final w = fillFuel.first.wish;
      final fuelCands = cands.where((k) => k.poi.kind == PoiKind.fuel).toList()
        ..sort((a, b) => a.alongM.compareTo(b.alongM));
      final fixed = chosen
          .where((e) => e.$1.kind == PoiKind.fuel)
          .map((e) => e.$2)
          .toList()
        ..sort();
      var pos = 0.0;
      for (final next in [...fixed, total]) {
        while (next - pos > fuelEveryM) {
          final reach = pos + fuelEveryM;
          final inRange =
              fuelCands.where((k) => k.alongM > pos + 1000 && k.alongM <= reach);
          // Ziel: nach rund 85 % der Reichweite tanken.
          var k = best(inRange, pos + fuelEveryM * 0.85);
          // Nichts in Reichweite: die naechste Tankstelle danach, damit
          // es ueberhaupt weitergeht (wird als Luecke gemeldet).
          k ??= fuelCands
              .where((c) => c.alongM > reach && c.alongM < next)
              .where((c) => !used.contains(c.poi.id))
              .firstOrNull;
          if (k == null) break;
          take(k, w);
          pos = k.alongM;
        }
        pos = next;
      }
    }

    chosen.sort((x, y) => x.$2.compareTo(y.$2));
    return chosen;
  }

  /// Wie viele Abschnitte laenger als die Reichweite sind (Start bis
  /// erste Tankstelle, zwischen zwei Tankstellen, letzte bis Ziel).
  static int fuelGaps(List<(Poi, double)> chosen, double totalM,
      {required double fuelEveryM, required bool wanted}) {
    if (!wanted) return 0;
    var gaps = 0, last = 0.0;
    final fuel = chosen.where((e) => e.$1.kind == PoiKind.fuel).map((e) => e.$2);
    for (final a in [...fuel, totalM]) {
      if (a - last > fuelEveryM * 1.05) gaps++;
      last = a;
    }
    return gaps;
  }

  /// Schiebt Stopps an der passenden Stelle zwischen die Wegpunkte.
  static List<Waypoint> insertStops(
    List<Waypoint> waypoints,
    List<(Poi, double)> stops,
    List<RoutePoint> pts,
  ) =>
      [for (final w in mergeWaypoints(waypoints, stops, pts)) w.$1];

  /// Wie [insertStops], aber mit der Position jedes Wegpunkts entlang
  /// der bisherigen Route (m ab Start).
  ///
  /// Start und Ziel liegen fest am Anfang und Ende - bei einer Rundtour
  /// sind sie derselbe Punkt, eine Projektion waere dort mehrdeutig.
  static List<(Waypoint, double)> mergeWaypoints(
    List<Waypoint> waypoints,
    List<(Poi, double)> stops,
    List<RoutePoint> pts,
  ) {
    if (pts.length < 2) return [for (final w in waypoints) (w, 0.0)];
    final cum = cumulativeDistances(pts);
    final along = <double>[0];
    var from = 0;
    for (var i = 1; i < waypoints.length - 1; i++) {
      final hit = projectOnPolyline(waypoints[i].point, pts, cum, from: from);
      if (hit != null) {
        along.add(math.max(hit.alongM, along.last));
        from = hit.segment;
      } else {
        along.add(along.last);
      }
    }
    along.add(cum.last);

    final out = <(Waypoint, double)>[];
    var s = 0;
    for (var i = 0; i < waypoints.length; i++) {
      if (i > 0) {
        while (s < stops.length && stops[s].$2 <= along[i]) {
          final p = stops[s].$1;
          out.add((Waypoint.at(p.lat, p.lon, WaypointKind.stop), stops[s].$2));
          s++;
        }
      }
      out.add((waypoints[i], along[i]));
    }
    return out;
  }

  /// Teilt eine lange Wegpunktliste in Stuecke, die der Server am Stueck
  /// rechnen kann: hoechstens [maxSpanM] Strecke und [maxCount] Punkte.
  /// Aufeinanderfolgende Stuecke teilen sich den Grenzpunkt. Zu grosse
  /// Luecken werden mit Punkten der bisherigen Route ueberbrueckt, damit
  /// deren Verlauf erhalten bleibt.
  static List<List<(Waypoint, double)>> chunkWaypoints(
    List<(Waypoint, double)> wps,
    List<RoutePoint> pts,
    List<double> cum, {
    double maxSpanM = 250000,
    int maxCount = 20,
  }) {
    final dense = <(Waypoint, double)>[];
    for (final w in wps) {
      if (dense.isNotEmpty) {
        final a0 = dense.last.$2;
        final gap = w.$2 - a0;
        final n = (gap / (maxSpanM * 0.9)).ceil();
        for (var i = 1; i < n; i++) {
          final a = a0 + gap * i / n;
          dense.add((Waypoint(pointAlong(pts, cum, a), WaypointKind.shape), a));
        }
      }
      dense.add(w);
    }
    final out = <List<(Waypoint, double)>>[];
    var cur = <(Waypoint, double)>[];
    for (final w in dense) {
      if (cur.length >= 2 &&
          (w.$2 - cur.first.$2 > maxSpanM || cur.length >= maxCount)) {
        out.add(cur);
        cur = [cur.last];
      }
      cur.add(w);
    }
    if (cur.length >= 2) out.add(cur);
    return out;
  }

  // -------------------------------------------------------------------------
  //  Hilfsfunktionen
  // -------------------------------------------------------------------------

  RoutePlan _toPlan(_Candidate c, RouteRequest req) {
    final km = (pathLength(c.route.points) / 1000).round();
    final title = req.title ??
        (req.roundTrip
            ? 'Rundtour · $km km'
            : 'Tour nach ${req.destinationName ?? 'Ziel'}');
    return RoutePlan(
      points: c.route.points,
      distanceM: c.route.distanceM,
      durationSec: c.route.durationSec,
      steps: c.route.steps,
      pois: c.pois,
      title: title,
      stats: c.quality.toStats(),
      engineLabel: engine.label,
      notes: c.notes,
      roundTrip: req.roundTrip,
      request: req,
    );
  }

  /// Entfernt fast gleiche Varianten - zwei Mal dieselbe Tour zur Auswahl
  /// zu stellen, hilft niemandem.
  static List<_Candidate> _distinct(List<_Candidate> sorted) {
    final out = <_Candidate>[];
    for (final c in sorted) {
      final dup = out.any((o) =>
          RouteScoring.similarity(o.route.points, c.route.points) > 0.75);
      if (!dup) out.add(c);
    }
    return out;
  }

  Object? _lastError;

  /// Fuehrt Aufgaben mit begrenzter Gleichzeitigkeit aus. Fehlgeschlagene
  /// Aufgaben liefern null; der letzte Fehler wird gemerkt.
  Future<List<T?>> _pool<T>(List<Future<T> Function()> jobs, int parallel) async {
    final results = List<T?>.filled(jobs.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= jobs.length) return;
        try {
          results[i] = await jobs[i]();
        } catch (e) {
          _lastError = e;
        }
      }
    }

    await Future.wait(
        List.generate(math.max(1, math.min(parallel, jobs.length)), (_) => worker()));
    return results;
  }
}

/// Schneidet Stichstrassen aus einer Engine-Route und passt Laenge,
/// Dauer und Anweisungen an.
EngineRoute cleanRoute(EngineRoute r, {List<RoutePoint> keep = const []}) {
  final cut = removeSpurs(r.points, keep: keep);
  if (!cut.changed) return r;
  final oldLen = pathLength(r.points);
  final ratio = oldLen > 0 ? pathLength(cut.points) / oldLen : 1.0;
  return EngineRoute(
    points: cut.points,
    distanceM: r.distanceM * ratio,
    durationSec: (r.durationSec * ratio).round(),
    steps: [
      for (final s in r.steps)
        if (s.pointIndex >= 0 &&
            s.pointIndex < cut.indexMap.length &&
            cut.indexMap[s.pointIndex] >= 0)
          RouteStep(
            text: s.text,
            distanceM: s.distanceM,
            pointIndex: cut.indexMap[s.pointIndex],
          ),
    ],
  );
}

import 'dart:async';
import 'dart:math' as math;

import '../models/ride.dart' show heatCellKey;
import '../models/route_plan.dart';
import 'geo.dart';
import 'poi_service.dart';
import 'routing_engine.dart';

export 'routing_engine.dart' show RouteException;

/// Meldet dem Bildschirm, woran der Planer gerade arbeitet.
typedef PlanProgress = void Function(String message);

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
  }) : _rnd = random ?? math.Random();

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
    final keep = req.stops.isEmpty ? maxVariants : math.min(2, maxVariants);
    cands = cands.take(keep).toList();

    if (req.stops.isNotEmpty) {
      final withStops = <_Candidate>[];
      for (var i = 0; i < cands.length; i++) {
        say(cands.length > 1
            ? 'Zwischenstopps werden gesucht (${i + 1}/${cands.length}) ...'
            : 'Zwischenstopps werden gesucht ...');
        withStops.add(await _attachStops(cands[i], req));
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
    final pts = <RoutePoint>[];
    final steps = <RouteStep>[];
    var distM = 0.0;
    var timeS = 0;
    for (var i = 0; i < stops.length - 1; i++) {
      say('Etappe ${i + 1}/${stops.length - 1} wird berechnet ...');
      final r = (await engine.route([
        Waypoint(stops[i], WaypointKind.endpoint),
        Waypoint(stops[i + 1], WaypointKind.endpoint),
      ], prefs))
          .first;
      final offset = pts.isEmpty ? 0 : pts.length - 1;
      pts.addAll(pts.isEmpty ? r.points : r.points.skip(1));
      for (final s in r.steps) {
        steps.add(RouteStep(
            text: s.text,
            distanceM: s.distanceM,
            pointIndex: s.pointIndex + offset));
      }
      distM += r.distanceM;
      timeS += r.durationSec;
    }
    return cleanRoute(EngineRoute(
        points: pts, distanceM: distM, durationSec: timeS, steps: steps));
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

  Future<_Candidate> _attachStops(_Candidate c, RouteRequest req) async {
    final pts = c.route.points;
    final cum = cumulativeDistances(pts);
    final total = cum.last;
    // Gesucht wird nur im Abschnitt um die Stelle, an der der Stopp liegen
    // soll - erst +-15 km, bei Misserfolg +-40 km. Eine Suche entlang der
    // GANZEN Route ist fuer den kostenlosen Kartendienst zu gross (er
    // bricht ab), und weit entfernte Treffer werden ohnehin nicht genommen.
    List<Poi>? found = <Poi>[];
    var failures = 0;
    for (var w = 0; w < req.stops.length; w++) {
      final wish = req.stops[w];
      final target = stopTarget(wish, w, req.stops.length, total);
      for (final half in const [15000.0, 40000.0]) {
        final res = await PoiService.searchAlongRoute(
          route: subPath(pts, cum, target - half, target + half),
          kinds: [wish.kind],
          corridorM: stopCorridorM,
        );
        if (res == null) {
          failures++;
          break;
        }
        for (final p in res) {
          if (!found.any((f) => f.id == p.id)) found.add(p);
        }
        if (res.any((p) => p.kind == wish.kind)) break;
      }
    }
    if (failures == req.stops.length) found = null;
    if (found == null) {
      return c.copyWith(notes: [
        ...c.notes,
        'Zwischenstopps konnten nicht gesucht werden '
            '(Kartendienst nicht erreichbar).',
      ]);
    }

    final notes = <String>[...c.notes];
    final chosen = chooseStops(pts, req.stops, found);
    for (final w in req.stops) {
      if (!chosen.any((e) => e.$1.kind == w.kind)) {
        notes.add('Keine ${w.kind.label} nah an der Route gefunden.');
      }
    }
    if (chosen.isEmpty) return c.copyWith(notes: notes);

    final room = engine.maxWaypoints - c.waypoints.length;
    final insert = chosen.take(math.max(0, room)).toList();
    if (insert.length < chosen.length) {
      notes.add('Nicht alle Stopps passen in die Route (Wegpunkt-Limit '
          'der Engine) - sie sind nur markiert.');
    }
    final wps = insertStops(c.waypoints, insert, pts);

    final stops = chosen.map((e) => e.$1).toList();
    try {
      final routes = await engine.route(wps, RoutingPrefs.of(req));
      final r = cleanRoute(routes.first,
          keep: [for (final p in stops) RoutePoint(p.lat, p.lon)]);
      final len = pathLength(r.points);
      final err = req.roundTrip
          ? (len - req.distanceKm * 1000).abs() / (req.distanceKm * 1000)
          : c.quality.lengthError;
      return c.copyWith(
        waypoints: wps,
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
    } on RouteException {
      notes.add('Die Route über die Stopps ließ sich nicht berechnen - '
          'die Stopps sind nur markiert.');
      return c.copyWith(pois: stops, notes: notes);
    }
  }

  /// Wo auf der Route (Meter ab Start) ein Stopp liegen soll: nach der
  /// gewuenschten Kilometerzahl, sonst gleichmaessig verteilt.
  static double stopTarget(StopWish wish, int index, int count, double total) =>
      wish.afterKm != null
          ? math.min(wish.afterKm! * 1000, total * 0.95)
          : total * (index + 1) / (count + 1);

  /// Suchstreifen links und rechts der Route fuer Zwischenstopps.
  static const double stopCorridorM = 1500;

  /// Waehlt zu jedem Stopp-Wunsch den passendsten Ort entlang der Route.
  ///
  /// Kriterien: nah an der gewuenschten Stelle (nach X km bzw.
  /// gleichmaessig verteilt), nah an der Strasse, und ein "guter" Ort
  /// (benannter Aussichtspunkt statt Gipfel im Wald). Beim Tanken ist
  /// "zu spaet" schlimmer als "zu frueh" - der Tank wird nicht voller.
  ///
  /// Rueckgabe: (Ort, Position entlang der Route in m), nach Position
  /// sortiert. Wuensche ohne passenden Ort fehlen in der Liste.
  static List<(Poi, double)> chooseStops(
    List<RoutePoint> pts,
    List<StopWish> wishes,
    List<Poi> found, {
    double corridorM = stopCorridorM,
  }) {
    if (pts.length < 2) return const [];
    final cum = cumulativeDistances(pts);
    final total = cum.last;
    final chosen = <(Poi, double)>[];
    for (var w = 0; w < wishes.length; w++) {
      final wish = wishes[w];
      final targetM = stopTarget(wish, w, wishes.length, total);
      Poi? best;
      var bestAlong = 0.0;
      var bestCost = double.infinity;
      for (final p in found) {
        if (p.kind != wish.kind || chosen.any((e) => e.$1.id == p.id)) continue;
        final hit = projectOnPolyline(RoutePoint(p.lat, p.lon), pts, cum);
        if (hit == null || hit.distanceM > corridorM) continue;
        var off = (hit.alongM - targetM) / 1000;
        if (wish.kind == PoiKind.fuel && off > 0) off *= 2;
        // Kosten in "Kilometern Umweg": 1 Punkt Qualitaet ist 3 km wert.
        final cost =
            off.abs() + 3 * hit.distanceM / 1000 - 3 * PoiService.stopQuality(p);
        if (cost < bestCost) {
          bestCost = cost;
          best = p;
          bestAlong = hit.alongM;
        }
      }
      if (best != null) {
        chosen.add(
            (best.copyWith(note: wish.reason, source: 'stop'), bestAlong));
      }
    }
    chosen.sort((x, y) => x.$2.compareTo(y.$2));
    return chosen;
  }

  /// Schiebt Stopps an der passenden Stelle zwischen die Wegpunkte.
  ///
  /// Start und Ziel liegen fest am Anfang und Ende - bei einer Rundtour
  /// sind sie derselbe Punkt, eine Projektion waere dort mehrdeutig.
  static List<Waypoint> insertStops(
    List<Waypoint> waypoints,
    List<(Poi, double)> stops,
    List<RoutePoint> pts,
  ) {
    if (stops.isEmpty || pts.length < 2) return List.of(waypoints);
    final cum = cumulativeDistances(pts);
    final along = <double>[0];
    var from = 0;
    for (var i = 1; i < waypoints.length - 1; i++) {
      final hit = projectOnPolyline(waypoints[i].point, pts, cum, from: from);
      if (hit != null) {
        along.add(hit.alongM);
        from = hit.segment;
      } else {
        along.add(along.last);
      }
    }
    along.add(cum.last);

    final out = <Waypoint>[];
    var s = 0;
    for (var i = 0; i < waypoints.length; i++) {
      if (i > 0) {
        while (s < stops.length && stops[s].$2 <= along[i]) {
          final p = stops[s].$1;
          out.add(Waypoint.at(p.lat, p.lon, WaypointKind.stop));
          s++;
        }
      }
      out.add(waypoints[i]);
    }
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

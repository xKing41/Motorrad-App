// Modelle rund um Routenplanung.
//
// WICHTIG fuer die KI-Anbindung:
// [RouteRequest] ist genau das, was ein Sprachmodell aus einem Satz wie
// "250 km kurvig, Mittagspause nach zwei Stunden, ein Aussichtspunkt"
// erzeugen soll. Das Modell erfindet dabei KEINE Koordinaten - es fuellt
// nur diese Parameter und nennt hoechstens Ortsnamen. Die echten Punkte
// kommen anschliessend aus Kartendaten (Ortssuche, POI-Suche) und die
// Route aus der Routing-Engine.
//
// Das dazugehoerige Schema steht in [routeRequestSchema] und wird direkt
// in den System-Prompt gegeben.

enum Curviness { direct, balanced, curvy, veryCurvy }

extension CurvinessX on Curviness {
  String get id => switch (this) {
        Curviness.direct => 'direct',
        Curviness.balanced => 'balanced',
        Curviness.curvy => 'curvy',
        Curviness.veryCurvy => 'very_curvy',
      };

  String get label => switch (this) {
        Curviness.direct => 'Direkt',
        Curviness.balanced => 'Ausgewogen',
        Curviness.curvy => 'Kurvig',
        Curviness.veryCurvy => 'Sehr kurvig',
      };

  static Curviness parse(String? s) => switch (s) {
        'direct' => Curviness.direct,
        'curvy' => Curviness.curvy,
        'very_curvy' => Curviness.veryCurvy,
        _ => Curviness.balanced,
      };
}

/// Himmelsrichtung fuer Rundtouren ("erst nach Norden, dann zurueck").
/// Bei [any] waehlt der Planer selbst und probiert mehrere Richtungen.
enum TourDirection { any, n, ne, e, se, s, sw, w, nw }

extension TourDirectionX on TourDirection {
  String get id => name;

  String get label => switch (this) {
        TourDirection.any => 'Egal',
        TourDirection.n => 'N',
        TourDirection.ne => 'NO',
        TourDirection.e => 'O',
        TourDirection.se => 'SO',
        TourDirection.s => 'S',
        TourDirection.sw => 'SW',
        TourDirection.w => 'W',
        TourDirection.nw => 'NW',
      };

  /// Kurs in Grad, null bei [TourDirection.any].
  double? get degrees => this == TourDirection.any
      ? null
      : (TourDirection.values.indexOf(this) - 1) * 45.0;

  static TourDirection parse(String? s) {
    for (final d in TourDirection.values) {
      if (d.name == s) return d;
    }
    return TourDirection.any;
  }
}

/// Arten von Zwischenstopps, die geplant werden koennen.
enum PoiKind { fuel, viewpoint, food, rest, water, workshop }

extension PoiKindX on PoiKind {
  String get id => name;

  String get label => switch (this) {
        PoiKind.fuel => 'Tankstelle',
        PoiKind.viewpoint => 'Aussicht / Foto',
        PoiKind.food => 'Einkehr',
        PoiKind.rest => 'Rastplatz',
        PoiKind.water => 'Trinkwasser',
        PoiKind.workshop => 'Werkstatt',
      };

  /// Passende Overpass-/OSM-Filter (ohne Elementtyp - gesucht wird in
  /// Punkten, Wegen und Relationen, denn viele Tankstellen sind als
  /// Flaeche eingetragen und nicht als Punkt).
  List<String> get osmFilters => switch (this) {
        PoiKind.fuel => ['["amenity"="fuel"]["access"!~"private|no"]'],
        PoiKind.viewpoint => [
            '["tourism"="viewpoint"]',
            '["natural"="peak"]["name"]',
          ],
        PoiKind.food => [
            '["amenity"="cafe"]',
            '["amenity"="restaurant"]',
            '["amenity"="biergarten"]',
          ],
        PoiKind.rest => [
            '["highway"="rest_area"]',
            '["tourism"="picnic_site"]',
            '["leisure"="picnic_table"]',
          ],
        PoiKind.water => ['["amenity"="drinking_water"]'],
        PoiKind.workshop => ['["shop"="motorcycle"]'],
      };

  static PoiKind? parse(String? s) {
    for (final k in PoiKind.values) {
      if (k.name == s) return k;
    }
    return null;
  }
}

/// Ein konkreter Ort auf der Karte. Kommt IMMER aus echten Kartendaten
/// oder vom Nutzer - niemals aus einem Sprachmodell.
class Poi {
  Poi({
    required this.id,
    required this.kind,
    required this.lat,
    required this.lon,
    this.name,
    this.note,
    this.detail,
    this.source = 'osm',
  });

  final String id;
  final PoiKind kind;
  final double lat;
  final double lon;
  final String? name;

  /// Freitext, den z. B. die KI ergaenzen darf ("guter Fotostopp am Hang").
  final String? note;

  /// Genauere Art aus den Kartendaten ("Gipfel", "Biergarten", Marke ...).
  final String? detail;

  /// 'osm' | 'user' | 'ride' | 'stop' - woher der Punkt stammt.
  /// 'stop' = vom Planer in die Route eingebauter Zwischenstopp.
  final String source;

  String get displayName => name?.isNotEmpty == true ? name! : kind.label;

  Poi copyWith({String? note, String? source}) => Poi(
        id: id,
        kind: kind,
        lat: lat,
        lon: lon,
        name: name,
        note: note ?? this.note,
        detail: detail,
        source: source ?? this.source,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.id,
        'lat': lat,
        'lon': lon,
        if (name != null) 'name': name,
        if (note != null) 'note': note,
        if (detail != null) 'detail': detail,
        'source': source,
      };

  static Poi fromJson(Map<String, dynamic> j) => Poi(
        id: j['id'] as String,
        kind: PoiKindX.parse(j['kind'] as String?) ?? PoiKind.rest,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        name: j['name'] as String?,
        note: j['note'] as String?,
        detail: j['detail'] as String?,
        source: j['source'] as String? ?? 'osm',
      );
}

/// Wunsch nach einem Stopp - noch ohne konkreten Ort.
/// Genau das darf ein Sprachmodell erzeugen.
class StopWish {
  StopWish({required this.kind, this.afterKm, this.reason});

  final PoiKind kind;

  /// Ungefaehr nach wie vielen Kilometern der Stopp liegen soll.
  final double? afterKm;
  final String? reason;

  Map<String, dynamic> toJson() => {
        'kind': kind.id,
        if (afterKm != null) 'after_km': afterKm,
        if (reason != null) 'reason': reason,
      };

  static StopWish fromJson(Map<String, dynamic> j) {
    final after = (j['after_km'] as num?)?.toDouble();
    final reason = j['reason'] as String?;
    return StopWish(
      kind: PoiKindX.parse(j['kind'] as String?) ?? PoiKind.rest,
      afterKm: (after != null && after > 0) ? after : null,
      reason: (reason != null && reason.trim().isNotEmpty) ? reason : null,
    );
  }
}

/// Strukturierte Routenanfrage - die Schnittstelle zwischen
/// Nutzerwunsch (ggf. per KI uebersetzt) und Routing-Engine.
class RouteRequest {
  RouteRequest({
    required this.startLat,
    required this.startLon,
    this.endLat,
    this.endLon,
    this.roundTrip = true,
    this.distanceKm = 150,
    this.curviness = Curviness.curvy,
    this.direction = TourDirection.any,
    this.viaLat,
    this.viaLon,
    this.avoidMotorways = true,
    this.avoidTolls = false,
    this.avoidUnpaved = true,
    this.stops = const [],
    this.preferKnownGoodRoads = false,
    this.title,
    this.destinationName,
    this.towardsName,
  });

  final double startLat;
  final double startLon;

  /// Ziel bei einer Strecke von A nach B.
  final double? endLat;
  final double? endLon;

  final bool roundTrip;
  final double distanceKm;
  final Curviness curviness;

  /// Grobe Richtung einer Rundtour.
  final TourDirection direction;

  /// Ort, ueber den (oder in dessen Richtung) die Rundtour fuehren soll.
  final double? viaLat;
  final double? viaLon;

  final bool avoidMotorways;
  final bool avoidTolls;
  final bool avoidUnpaved;
  final List<StopWish> stops;

  /// Nutzt die eigenen Fahrdaten: bevorzugt Strassen, auf denen der
  /// Fahrer schon unterwegs war und gut lag. Das kann sonst niemand.
  final bool preferKnownGoodRoads;

  final String? title;

  /// Ortsnamen, wie sie die KI verstanden hat. Die Koordinaten dazu
  /// sucht die App selbst in den Kartendaten.
  final String? destinationName;
  final String? towardsName;

  bool get hasEnd => endLat != null && endLon != null;
  bool get hasVia => viaLat != null && viaLon != null;

  RouteRequest copyWith({
    double? startLat,
    double? startLon,
    double? endLat,
    double? endLon,
    bool clearEnd = false,
    bool? roundTrip,
    double? distanceKm,
    Curviness? curviness,
    TourDirection? direction,
    double? viaLat,
    double? viaLon,
    bool clearVia = false,
    bool? avoidMotorways,
    bool? avoidTolls,
    bool? avoidUnpaved,
    List<StopWish>? stops,
    bool? preferKnownGoodRoads,
    String? title,
  }) =>
      RouteRequest(
        startLat: startLat ?? this.startLat,
        startLon: startLon ?? this.startLon,
        endLat: clearEnd ? null : (endLat ?? this.endLat),
        endLon: clearEnd ? null : (endLon ?? this.endLon),
        roundTrip: roundTrip ?? this.roundTrip,
        distanceKm: distanceKm ?? this.distanceKm,
        curviness: curviness ?? this.curviness,
        direction: direction ?? this.direction,
        viaLat: clearVia ? null : (viaLat ?? this.viaLat),
        viaLon: clearVia ? null : (viaLon ?? this.viaLon),
        avoidMotorways: avoidMotorways ?? this.avoidMotorways,
        avoidTolls: avoidTolls ?? this.avoidTolls,
        avoidUnpaved: avoidUnpaved ?? this.avoidUnpaved,
        stops: stops ?? this.stops,
        preferKnownGoodRoads: preferKnownGoodRoads ?? this.preferKnownGoodRoads,
        title: title ?? this.title,
        destinationName: destinationName,
        towardsName: towardsName,
      );

  Map<String, dynamic> toJson() => {
        'start': {'lat': startLat, 'lon': startLon},
        if (hasEnd) 'end': {'lat': endLat, 'lon': endLon},
        'round_trip': roundTrip,
        'distance_km': distanceKm,
        'curviness': curviness.id,
        'direction': direction.id,
        'avoid_motorways': avoidMotorways,
        'avoid_tolls': avoidTolls,
        'avoid_unpaved': avoidUnpaved,
        'stops': stops.map((s) => s.toJson()).toList(),
        'prefer_known_good_roads': preferKnownGoodRoads,
        if (title != null) 'title': title,
      };

  /// Baut eine Anfrage aus dem JSON, das ein Sprachmodell liefert.
  ///
  /// Koordinaten werden bewusst NICHT aus dem Modell uebernommen - auch
  /// dann nicht, wenn es welche schickt. Start ist immer die Position der
  /// App, Ziele kommen nur als Name und werden danach in echten
  /// Kartendaten gesucht.
  static RouteRequest fromModelJson(
    Map<String, dynamic> j, {
    required double startLat,
    required double startLon,
  }) {
    final stopsRaw = (j['stops'] as List?) ?? const [];
    String? name(String key) {
      final v = j[key];
      if (v is! String) return null;
      final t = v.trim();
      return t.isEmpty ? null : t;
    }

    final destination = name('destination');
    return RouteRequest(
      startLat: startLat,
      startLon: startLon,
      roundTrip: destination == null && (j['round_trip'] as bool? ?? true),
      distanceKm: (j['distance_km'] as num?)?.toDouble() ?? 150,
      curviness: CurvinessX.parse(j['curviness'] as String?),
      direction: TourDirectionX.parse(j['direction'] as String?),
      avoidMotorways: j['avoid_motorways'] as bool? ?? true,
      avoidTolls: j['avoid_tolls'] as bool? ?? false,
      avoidUnpaved: j['avoid_unpaved'] as bool? ?? true,
      stops: stopsRaw
          .whereType<Map<String, dynamic>>()
          .map(StopWish.fromJson)
          .toList(),
      preferKnownGoodRoads: j['prefer_known_good_roads'] as bool? ?? false,
      title: name('title'),
      destinationName: destination,
      towardsName: name('towards'),
    );
  }
}

/// Ein Punkt der berechneten Route.
class RoutePoint {
  const RoutePoint(this.lat, this.lon);
  final double lat;
  final double lon;

  @override
  String toString() => 'RoutePoint($lat, $lon)';
}

/// Eine Abbiegeanweisung.
class RouteStep {
  RouteStep({
    required this.text,
    required this.distanceM,
    required this.pointIndex,
  });

  final String text;
  final double distanceM;
  final int pointIndex;
}

/// Kennzahlen einer geplanten Route - damit der Fahrer sieht, warum der
/// Planer genau diese Variante vorschlaegt.
class RouteStats {
  const RouteStats({
    required this.curvIndex,
    required this.curvLabel,
    required this.bendsPerKm,
    required this.overlapShare,
    required this.knownShare,
    required this.score,
  });

  /// 0 = gerade, ~0,7 = typische kurvige Landstrasse, 1,5 = Alpenpass.
  final double curvIndex;
  final String curvLabel;
  final double bendsPerKm;

  /// Anteil doppelt befahrener Strecke (0..1).
  final double overlapShare;

  /// Anteil der Strecke, den der Fahrer schon einmal gefahren ist (0..1).
  final double knownShare;

  /// Gesamtbewertung des Planers - nur zum Vergleichen der Varianten.
  final double score;
}

/// Das Ergebnis der Planung: fertige Route zum Anzeigen und Abfahren.
class RoutePlan {
  RoutePlan({
    required this.points,
    required this.distanceM,
    this.durationSec = 0,
    this.steps = const [],
    this.pois = const [],
    this.title,
    this.description,
    this.stats,
    this.engineLabel,
    this.alternatives = const [],
    this.notes = const [],
  });

  final List<RoutePoint> points;
  final double distanceM;
  final int durationSec;
  final List<RouteStep> steps;
  final List<Poi> pois;
  final String? title;

  /// Erzaehlender Text - darf von der KI kommen.
  final String? description;

  /// Kennzahlen, falls die Route vom Planer stammt (nicht bei GPX).
  final RouteStats? stats;

  /// Welche Routing-Engine die Route berechnet hat.
  final String? engineLabel;

  /// Weitere Vorschlaege, schlechter bewertet als diese Route.
  final List<RoutePlan> alternatives;

  /// Hinweise des Planers ("Tankstelle nicht gefunden" ...).
  final List<String> notes;

  double get distanceKm => distanceM / 1000;
  bool get isEmpty => points.length < 2;

  RoutePlan copyWith({
    List<RoutePoint>? points,
    double? distanceM,
    int? durationSec,
    List<RouteStep>? steps,
    List<Poi>? pois,
    String? title,
    String? description,
    RouteStats? stats,
    String? engineLabel,
    List<RoutePlan>? alternatives,
    List<String>? notes,
  }) =>
      RoutePlan(
        points: points ?? this.points,
        distanceM: distanceM ?? this.distanceM,
        durationSec: durationSec ?? this.durationSec,
        steps: steps ?? this.steps,
        pois: pois ?? this.pois,
        title: title ?? this.title,
        description: description ?? this.description,
        stats: stats ?? this.stats,
        engineLabel: engineLabel ?? this.engineLabel,
        alternatives: alternatives ?? this.alternatives,
        notes: notes ?? this.notes,
      );
}

/// Schema fuer den KI-System-Prompt (lesbare Fassung). Die technisch
/// erzwungene Fassung steht in ai_planner.dart - beide muessen
/// zusammenpassen.
const String routeRequestSchema = '''
{
  "round_trip": true,
  "distance_km": 180,
  "curviness": "direct | balanced | curvy | very_curvy",
  "direction": "any | n | ne | e | se | s | sw | w | nw",
  "towards": "Ort oder Gegend, ueber die die Rundtour fuehren soll - sonst null",
  "destination": "Zielort, wenn die Tour NICHT zum Start zurueckfuehrt - sonst null",
  "avoid_motorways": true,
  "avoid_tolls": false,
  "avoid_unpaved": true,
  "prefer_known_good_roads": false,
  "title": "kurzer Tourname",
  "stops": [
    {
      "kind": "fuel | viewpoint | food | rest | water | workshop",
      "after_km": 90,
      "reason": "kurze Begruendung fuer den Fahrer"
    }
  ],
  "reply": "ein bis zwei Saetze, was geplant wird",
  "safety_note": "nur bei riskanten Wuenschen, sonst null"
}
''';

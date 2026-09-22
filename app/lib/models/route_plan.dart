/// Modelle rund um Routenplanung.
///
/// WICHTIG fuer die spaetere KI-Anbindung:
/// [RouteRequest] ist genau das, was ein Sprachmodell aus einem Satz wie
/// "250 km kurvig, Mittagspause nach zwei Stunden, ein Aussichtspunkt"
/// erzeugen soll. Das Modell erfindet dabei KEINE Koordinaten - es fuellt
/// nur diese Parameter. Die echten Punkte kommen anschliessend aus
/// Kartendaten (POI-Suche) und die Route aus der Routing-Engine.
///
/// Das dazugehoerige JSON-Schema steht in [routeRequestSchema] und kann
/// direkt in den System-Prompt gegeben werden.

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

  /// Uebersetzung in ein GraphHopper-Custom-Model.
  /// curvature ist dort "Luftlinie / Streckenlaenge" (0..1),
  /// kleine Werte = kurvige Strasse.
  Map<String, dynamic> toGraphHopperCustomModel() {
    final priority = <Map<String, dynamic>>[];
    switch (this) {
      case Curviness.direct:
        break;
      case Curviness.balanced:
        priority.add({'if': 'curvature < 0.9', 'multiply_by': '1.3'});
        break;
      case Curviness.curvy:
        priority
          ..add({'if': 'curvature < 0.95', 'multiply_by': '2.0'})
          ..add({'if': 'road_class == MOTORWAY', 'multiply_by': '0.1'});
        break;
      case Curviness.veryCurvy:
        priority
          ..add({'if': 'curvature < 0.97', 'multiply_by': '4.0'})
          ..add({'if': 'road_class == MOTORWAY', 'multiply_by': '0.02'})
          ..add({'if': 'road_class == TRUNK', 'multiply_by': '0.3'});
        break;
    }
    return {
      'priority': priority,
      'distance_influence': this == Curviness.direct ? 90 : 15,
    };
  }

  static Curviness parse(String? s) => switch (s) {
        'direct' => Curviness.direct,
        'curvy' => Curviness.curvy,
        'very_curvy' => Curviness.veryCurvy,
        _ => Curviness.balanced,
      };
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

  /// Passender Overpass-/OSM-Filter fuer diese Kategorie.
  List<String> get osmFilters => switch (this) {
        PoiKind.fuel => ['node["amenity"="fuel"]'],
        PoiKind.viewpoint => [
            'node["tourism"="viewpoint"]',
            'node["natural"="peak"]',
          ],
        PoiKind.food => [
            'node["amenity"="cafe"]',
            'node["amenity"="restaurant"]',
          ],
        PoiKind.rest => [
            'node["highway"="rest_area"]',
            'node["tourism"="picnic_site"]',
            'node["leisure"="picnic_table"]',
          ],
        PoiKind.water => ['node["amenity"="drinking_water"]'],
        PoiKind.workshop => ['node["shop"="motorcycle"]'],
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
    this.source = 'osm',
  });

  final String id;
  final PoiKind kind;
  final double lat;
  final double lon;
  final String? name;

  /// Freitext, den z. B. die KI ergaenzen darf ("guter Fotostopp am Hang").
  final String? note;

  /// 'osm' | 'user' | 'ride' - woher der Punkt stammt.
  final String source;

  String get displayName => name?.isNotEmpty == true ? name! : kind.label;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.id,
        'lat': lat,
        'lon': lon,
        if (name != null) 'name': name,
        if (note != null) 'note': note,
        'source': source,
      };

  static Poi fromJson(Map<String, dynamic> j) => Poi(
        id: j['id'] as String,
        kind: PoiKindX.parse(j['kind'] as String?) ?? PoiKind.rest,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        name: j['name'] as String?,
        note: j['note'] as String?,
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

  static StopWish fromJson(Map<String, dynamic> j) => StopWish(
        kind: PoiKindX.parse(j['kind'] as String?) ?? PoiKind.rest,
        afterKm: (j['after_km'] as num?)?.toDouble(),
        reason: j['reason'] as String?,
      );
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
    this.avoidMotorways = true,
    this.avoidTolls = false,
    this.avoidUnpaved = true,
    this.stops = const [],
    this.preferKnownGoodRoads = false,
    this.title,
  });

  final double startLat;
  final double startLon;
  final double? endLat;
  final double? endLon;
  final bool roundTrip;
  final double distanceKm;
  final Curviness curviness;
  final bool avoidMotorways;
  final bool avoidTolls;
  final bool avoidUnpaved;
  final List<StopWish> stops;

  /// Nutzt die eigenen Fahrdaten: bevorzugt Strassen, auf denen der
  /// Fahrer schon unterwegs war und gut lag. Das kann sonst niemand.
  final bool preferKnownGoodRoads;

  final String? title;

  Map<String, dynamic> toJson() => {
        'start': {'lat': startLat, 'lon': startLon},
        if (endLat != null && endLon != null)
          'end': {'lat': endLat, 'lon': endLon},
        'round_trip': roundTrip,
        'distance_km': distanceKm,
        'curviness': curviness.id,
        'avoid_motorways': avoidMotorways,
        'avoid_tolls': avoidTolls,
        'avoid_unpaved': avoidUnpaved,
        'stops': stops.map((s) => s.toJson()).toList(),
        'prefer_known_good_roads': preferKnownGoodRoads,
        if (title != null) 'title': title,
      };

  /// Baut eine Anfrage aus dem JSON, das ein Sprachmodell liefert.
  /// Start/Ziel werden bewusst NICHT aus dem Modell uebernommen, sondern
  /// von der App gesetzt (aktuelle Position oder Nutzereingabe).
  static RouteRequest fromModelJson(
    Map<String, dynamic> j, {
    required double fallbackLat,
    required double fallbackLon,
  }) {
    final start = j['start'] as Map<String, dynamic>?;
    final end = j['end'] as Map<String, dynamic>?;
    final stopsRaw = (j['stops'] as List?) ?? const [];
    return RouteRequest(
      startLat: (start?['lat'] as num?)?.toDouble() ?? fallbackLat,
      startLon: (start?['lon'] as num?)?.toDouble() ?? fallbackLon,
      endLat: (end?['lat'] as num?)?.toDouble(),
      endLon: (end?['lon'] as num?)?.toDouble(),
      roundTrip: j['round_trip'] as bool? ?? true,
      distanceKm: (j['distance_km'] as num?)?.toDouble() ?? 150,
      curviness: CurvinessX.parse(j['curviness'] as String?),
      avoidMotorways: j['avoid_motorways'] as bool? ?? true,
      avoidTolls: j['avoid_tolls'] as bool? ?? false,
      avoidUnpaved: j['avoid_unpaved'] as bool? ?? true,
      stops: stopsRaw
          .whereType<Map<String, dynamic>>()
          .map(StopWish.fromJson)
          .toList(),
      preferKnownGoodRoads: j['prefer_known_good_roads'] as bool? ?? false,
      title: j['title'] as String?,
    );
  }
}

/// Ein Punkt der berechneten Route.
class RoutePoint {
  const RoutePoint(this.lat, this.lon);
  final double lat;
  final double lon;
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
  });

  final List<RoutePoint> points;
  final double distanceM;
  final int durationSec;
  final List<RouteStep> steps;
  final List<Poi> pois;
  final String? title;

  /// Erzaehlender Text - darf spaeter von der KI kommen.
  final String? description;

  double get distanceKm => distanceM / 1000;
  bool get isEmpty => points.length < 2;
}

/// JSON-Schema fuer den KI-System-Prompt.
/// Bewusst als Konstante hier, damit Modell und Prompt nie auseinanderlaufen.
const String routeRequestSchema = '''
{
  "round_trip": true,
  "distance_km": 180,
  "curviness": "direct | balanced | curvy | very_curvy",
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
  ]
}
''';

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/ride.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/ai_planner.dart';
import 'package:schraeglage/services/poi_service.dart';

void main() {
  group('KI-Antwort -> RouteRequest', () {
    test('Ziel gesetzt: keine Rundtour, Koordinaten kommen NIE vom Modell', () {
      final r = RouteRequest.fromModelJson({
        'round_trip': true,
        'distance_km': 200,
        'curviness': 'very_curvy',
        'direction': 'nw',
        'destination': 'Winterberg',
        'towards': null,
        // Versuch des Modells, Koordinaten unterzuschieben:
        'start': {'lat': 1.0, 'lon': 2.0},
        'end': {'lat': 3.0, 'lon': 4.0},
        'stops': [
          {'kind': 'fuel', 'after_km': null, 'reason': ''},
          {'kind': 'viewpoint', 'after_km': 90, 'reason': 'Pause'},
        ],
      }, startLat: 51.3, startLon: 7.35);
      expect(r.roundTrip, isFalse);
      expect(r.destinationName, 'Winterberg');
      expect(r.startLat, 51.3);
      expect(r.startLon, 7.35);
      expect(r.hasEnd, isFalse);
      expect(r.curviness, Curviness.veryCurvy);
      expect(r.direction, TourDirection.nw);
      expect(r.stops[0].afterKm, isNull);
      expect(r.stops[0].reason, isNull);
      expect(r.stops[1].afterKm, 90);
    });

    test('leere Namen gelten als nicht angegeben', () {
      final r = RouteRequest.fromModelJson(
          {'destination': '  ', 'towards': ''}, startLat: 1, startLon: 2);
      expect(r.roundTrip, isTrue);
      expect(r.destinationName, isNull);
      expect(r.towardsName, isNull);
    });

    test('Himmelsrichtungen in Grad', () {
      expect(TourDirection.any.degrees, isNull);
      expect(TourDirection.n.degrees, 0);
      expect(TourDirection.e.degrees, 90);
      expect(TourDirection.sw.degrees, 225);
      expect(TourDirection.nw.degrees, 315);
    });

    test('erzwungenes Schema: jedes Feld ist Pflicht, keine Extras', () {
      const s = AiRoutePlanner.outputSchema;
      expect(s['additionalProperties'], isFalse);
      final props = (s['properties'] as Map).keys.toSet();
      expect((s['required'] as List).toSet(), props);
      final stop = ((s['properties'] as Map)['stops'] as Map)['items'] as Map;
      expect(stop['additionalProperties'], isFalse);
      expect((stop['required'] as List).toSet(),
          (stop['properties'] as Map).keys.toSet());
      // Die lesbare Fassung im Prompt nennt dieselben Felder.
      for (final k in props) {
        expect(routeRequestSchema, contains('"$k"'));
      }
    });
  });

  group('Overpass', () {
    test('Limit gilt je Art, gesucht wird in Punkten UND Flaechen', () {
      final q = PoiService.buildQuery(
          [PoiKind.fuel, PoiKind.food], '(around:100,51,7)', 12);
      expect('out center 12;'.allMatches(q).length, 2);
      expect(q, contains('nwr["amenity"="fuel"]'));
      expect(q, isNot(contains('node[')));
    });

    test('Tankstelle als Punkt und Flaeche wird nur einmal gezaehlt', () {
      final list = PoiService.parseElements({
        'elements': [
          {
            'type': 'node',
            'id': 1,
            'lat': 51.0,
            'lon': 7.0,
            'tags': {'amenity': 'fuel', 'brand': 'Aral'},
          },
          {
            'type': 'way',
            'id': 2,
            'center': {'lat': 51.0001, 'lon': 7.0001},
            'tags': {'amenity': 'fuel', 'name': 'Aral Station'},
          },
          {
            'type': 'node',
            'id': 3,
            'lat': 51.1,
            'lon': 7.1,
            'tags': {'natural': 'peak', 'name': 'Berg', 'ele': '600'},
          },
        ],
      }, [PoiKind.fuel, PoiKind.viewpoint]);
      expect(list.length, 2);
      expect(list.first.detail, 'Aral');
      expect(list.last.detail, 'Gipfel, 600 m');
    });
  });

  test('Durchschnitt ohne Pausen', () {
    final r = RideSummary(
      id: 'x',
      start: DateTime(2026),
      durationSec: 7200,
      distanceM: 60000,
      maxLeanL: 0,
      maxLeanR: 0,
      maxSpeedMs: 0,
      maxBrakeG: 0,
      maxLatG: 0,
      pointCount: 0,
      movingSec: 3600,
    );
    expect(r.avgSpeedKmh, closeTo(60, 1e-9));
    expect(RideSummary.fromJson(r.toJson()).movingSec, 3600);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geocoder.dart';

void main() {
  group('Koordinaten', () {
    void expectAt(String s, double lat, double lon) {
      final c = Geocoder.parseCoordinates(s);
      expect(c, isNotNull, reason: s);
      expect(c!.lat, closeTo(lat, 1e-4), reason: s);
      expect(c.lon, closeTo(lon, 1e-4), reason: s);
    }

    test('dezimal, auch deutsch geschrieben', () {
      expectAt('51.4567, 7.1234', 51.4567, 7.1234);
      expectAt('51.4567 7.1234', 51.4567, 7.1234);
      expectAt('51,4567 7,1234', 51.4567, 7.1234);
      expectAt('51,4567; 7,1234', 51.4567, 7.1234);
      expectAt('-33.86, 151.21', -33.86, 151.21);
    });

    test('Grad, Minuten, Sekunden', () {
      expectAt('51°27\'24"N 7°7\'12"E', 51.45667, 7.12);
      expectAt('N 51° 27.4\' E 7° 7.2\'', 51.45667, 7.12);
      expectAt('47°30\'S 8°W', -47.5, -8);
    });

    test('Links aus Karten-Apps', () {
      expectAt('https://www.google.com/maps/place/Foo/@51.4567,7.1234,15z',
          51.4567, 7.1234);
      expectAt('https://maps.google.com/?q=48.1,11.5', 48.1, 11.5);
      expectAt('geo:47.2,9.8?z=12', 47.2, 9.8);
    });

    test('keine Koordinaten', () {
      expect(Geocoder.parseCoordinates('Winterberg'), isNull);
      expect(Geocoder.parseCoordinates('Hauptstraße 12'), isNull);
      expect(Geocoder.parseCoordinates('58300 Wetter'), isNull);
      expect(Geocoder.parseCoordinates('95.1, 7.2'), isNull);
    });
  });

  test('Kategorien in der Naehe', () {
    expect(Geocoder.categoryOf('Tankstelle'), PoiKind.fuel);
    expect(Geocoder.categoryOf('nächste Tanke'), PoiKind.fuel);
    expect(Geocoder.categoryOf('Cafe in der Nähe'), PoiKind.food);
    expect(Geocoder.categoryOf('Aussichtspunkt'), PoiKind.viewpoint);
    expect(Geocoder.categoryOf('Motorradwerkstatt'), PoiKind.workshop);
    // Name eines bestimmten Orts ist keine Kategorie.
    expect(Geocoder.categoryOf('Tankstelle Aral Hagen'), isNull);
    expect(Geocoder.categoryOf('Winterberg'), isNull);
  });

  test('Ergebnisse zusammenfuehren: Doppelte nur einmal', () {
    const a = Place(name: 'Winterberg', lat: 51.195, lon: 8.53, kind: 'Stadt');
    const b = Place(name: 'Winterberg', lat: 51.196, lon: 8.531); // 130 m
    const c = Place(name: 'Kahler Asten', lat: 51.18, lon: 8.49);
    const d = Place(name: 'Anderer Name', lat: 51.18001, lon: 8.49001); // 1 m
    final m = Geocoder.merge([
      [a, c],
      [b, d],
    ]);
    expect(m.map((p) => p.name), ['Winterberg', 'Kahler Asten']);
    expect(m.first.kind, 'Stadt');
  });

  test('Photon: Hausnummer, benannter Ort mit Adresse, Art', () {
    final l = Geocoder.parsePhoton({
      'features': [
        {
          'geometry': {'coordinates': [7.3, 51.4]},
          'properties': {
            'street': 'Hauptstraße',
            'housenumber': '12',
            'postcode': '58300',
            'city': 'Wetter',
            'osm_key': 'building',
          },
        },
        {
          'geometry': {'coordinates': [8.1, 51.2]},
          'properties': {
            'name': 'Gasthof Zur Post',
            'street': 'Dorfstraße',
            'housenumber': '3',
            'city': 'Winterberg',
            'osm_key': 'amenity',
            'osm_value': 'restaurant',
          },
        },
        {
          'geometry': {'coordinates': [10.45, 46.53]},
          'properties': {
            'name': 'Stilfser Joch',
            'osm_key': 'mountain_pass',
            'osm_value': 'yes',
            'country': 'Italien',
          },
        },
      ],
    });
    expect(l[0].name, 'Hauptstraße 12');
    expect(l[0].kind, 'Adresse');
    expect(l[0].detail, '58300 Wetter');
    expect(l[1].name, 'Gasthof Zur Post');
    expect(l[1].detail, startsWith('Dorfstraße 3, Winterberg'));
    expect(l[1].kind, 'Restaurant');
    expect(l[2].detail, 'Italien');
  });

  test('Nominatim wird gelesen', () {
    final l = Geocoder.parseNominatim([
      {
        'lat': '51.18',
        'lon': '8.49',
        'name': 'Kahler Asten',
        'display_name': 'Kahler Asten, Winterberg, Hochsauerlandkreis, NRW, DE',
        'category': 'natural',
        'type': 'peak',
      },
    ]);
    expect(l.single.name, 'Kahler Asten');
    expect(l.single.kind, 'Gipfel');
    expect(l.single.detail, 'Winterberg, Hochsauerlandkreis, NRW');
  });

  test('Entfernung als Text', () {
    expect(Geocoder.distanceText(830), '850 m');
    expect(Geocoder.distanceText(4230), '4,2 km');
    expect(Geocoder.distanceText(123456), '123 km');
  });
}

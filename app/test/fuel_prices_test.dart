import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/fuel_prices.dart';

Map<String, dynamic> answer() => {
      'ok': true,
      'status': 'ok',
      'stations': [
        {
          'id': 'a1',
          'name': 'ARAL Tankstelle',
          'brand': 'ARAL',
          'lat': 48.10050,
          'lng': 9.20000,
          'isOpen': true,
          'e5': 1.839,
          'e10': 1.779,
          'diesel': 1.699,
        },
        {
          'id': 'b2',
          'name': 'Freie Tanke',
          'brand': '',
          'lat': 48.1100,
          'lng': 9.2000,
          'isOpen': false,
          'e5': false,
          'e10': 1.749,
          'diesel': null,
        },
      ],
    };

void main() {
  test('Antwort lesen: fehlende Preise sind null', () {
    final s = FuelPrices.parse(answer());
    expect(s.length, 2);
    expect(s[0].e5, 1.839);
    expect(s[1].e5, isNull);
    expect(s[1].brand, isNull);
    expect(s[1].isOpen, isFalse);
  });

  test('Fehlermeldung des Dienstes wird weitergegeben', () {
    expect(
        () => FuelPrices.parse({'ok': false, 'message': 'apikey nicht gültig'}),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', 'apikey nicht gültig')));
  });

  test('Tankstopp wird der Tankstelle am selben Ort zugeordnet', () {
    final stations = FuelPrices.parse(answer());
    final stop = Poi(
        id: 's', kind: PoiKind.fuel, lat: 48.1, lon: 9.2, source: 'stop');
    expect(FuelPrices.match(stop, stations)!.id, 'a1'); // 55 m
    final far = Poi(
        id: 'f', kind: PoiKind.fuel, lat: 48.105, lon: 9.2, source: 'stop');
    expect(FuelPrices.match(far, stations), isNull); // 550 m / 555 m
  });

  test('Preise fuer die Tankstopps, Anzeige wie an der Zapfsaeule', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      expect(req.url.queryParameters['apikey'], 'KEY');
      return http.Response(jsonEncode(answer()), 200);
    });
    final fp = FuelPrices('KEY', client: client);
    final m = await fp.forStops([
      Poi(id: 's', kind: PoiKind.fuel, lat: 48.1, lon: 9.2, source: 'stop'),
      Poi(id: 'v', kind: PoiKind.viewpoint, lat: 48.1, lon: 9.2),
    ], FuelType.e10);
    expect(calls, 1); // nur Tankstopps
    expect(m['s']!.text, 'E10 1,779 €');
    final closed = StopPrice(FuelPrices.parse(answer())[1], FuelType.e5);
    expect(closed.text, 'E5: kein Preis · geschlossen');
  });
}

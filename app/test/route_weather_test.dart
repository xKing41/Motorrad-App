import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/route_weather.dart';

import 'helpers.dart';

/// Vorhersage mit Stundenwerten ab [start]; [rain] liefert mm je Stunde.
Map<String, dynamic> hourly(DateTime start, int hours,
    {required double Function(int h) rain,
    double Function(int h)? temp,
    double Function(int h)? gust}) {
  return {
    'hourly': {
      'time': [
        for (var h = 0; h < hours; h++)
          start.add(Duration(hours: h)).millisecondsSinceEpoch ~/ 1000,
      ],
      'precipitation': [for (var h = 0; h < hours; h++) rain(h)],
      'precipitation_probability': [
        for (var h = 0; h < hours; h++) rain(h) > 0 ? 80 : 5,
      ],
      'temperature_2m': [for (var h = 0; h < hours; h++) temp?.call(h) ?? 15],
      'wind_gusts_10m': [for (var h = 0; h < hours; h++) gust?.call(h) ?? 20],
      'weather_code': [for (var h = 0; h < hours; h++) rain(h) > 0 ? 61 : 1],
    },
  };
}

void main() {
  const home = RoutePoint(48.0, 9.0);
  final t0 = DateTime(2026, 6, 1, 8);

  test('Stellen: Start, gleichmaessig, Ziel', () {
    final pts = straight(home, 90, 100000, step: 200);
    final s = RouteWeather.samplePoints(pts);
    expect(s.first.$2, 0);
    expect(s.last.$2, closeTo(100000, 1));
    expect(s.length, 6); // alle 20 km
    final from = RouteWeather.samplePoints(pts, fromM: 60000);
    expect(from.first.$2, closeTo(60000, 1));
  });

  test('Antwort mit mehreren Orten wird gelesen', () {
    final s = RouteWeather.parseMulti([
      hourly(t0, 5, rain: (_) => 0),
      hourly(t0, 5, rain: (_) => 1),
    ])!;
    expect(s.length, 2);
    expect(s[1].rainMm[2], 1);
    expect(s[0].code[0], 1);
    expect(RouteWeather.parseMulti({'error': true, 'reason': 'x'}), isNull);
  });

  test('Regen erst dort, wo man spaet ankommt: "ab km ... gegen ..."', () {
    // 4 Stellen (0, 40, 80, 120 km), 3 Stunden Fahrt, Regen ab 10 Uhr
    // ueberall.
    final series = RouteWeather.parseMulti([
      for (var i = 0; i < 4; i++) hourly(t0, 24, rain: (h) => h >= 3 ? 2 : 0),
    ])!;
    final w = RouteWeather([0, 40000, 80000, 120000], series);
    final r = w.at(t0, 3 * 3600);
    // Ankunft: 8:00, 9:00, 10:00, 11:00. Wer um 10:00 bei km 80 ist,
    // faehrt 10-11 Uhr (Wert zum Zeitstempel 11:00) - nass.
    expect(r.firstWet!.alongM, 80000);
    expect(r.warnings().first, 'Regen ab km 80 (gegen 10:00)');
    expect(r.dry, isFalse);

    // Frueher los: trocken.
    final early = w.at(t0.subtract(const Duration(hours: 1)), 2 * 3600);
    expect(early.dry, isTrue);
    expect(early.summary(), startsWith('Trocken auf der ganzen Strecke'));
  });

  test('wieder trocken, Kaelte und Boeen werden genannt', () {
    final series = RouteWeather.parseMulti([
      hourly(t0, 24, rain: (_) => 0),
      hourly(t0, 24, rain: (_) => 1.5, temp: (_) => 2),
      hourly(t0, 24, rain: (_) => 0, gust: (_) => 75),
    ])!;
    final w = RouteWeather([0, 50000, 100000], series);
    final r = w.at(t0, 2 * 3600);
    final warn = r.warnings();
    expect(warn[0], contains('Regen ab km 50'));
    expect(warn[0], contains('ab km 100 wieder trocken'));
    expect(warn[1], 'Frostgefahr: 2 °C bei km 50');
    expect(warn[2], 'Böen bis 75 km/h bei km 100');
  });

  test('bessere Abfahrt wird vorgeschlagen, wenn es spaeter trocken ist', () {
    final now = DateTime(2026, 6, 1, 8, 20);
    // Regen bis 11 Uhr, danach trocken.
    final series = RouteWeather.parseMulti([
      for (var i = 0; i < 3; i++)
        hourly(DateTime(2026, 6, 1, 0), 48, rain: (h) => h <= 11 ? 2 : 0),
    ])!;
    final w = RouteWeather([0, 30000, 60000], series);
    expect(w.at(now, 3600).dry, isFalse);
    final best = w.betterDeparture(now, 3600)!;
    expect(best.dry, isTrue);
    expect(best.departure.hour, 11);
  });

  test('schon trocken: kein Vorschlag', () {
    final series = RouteWeather.parseMulti([
      for (var i = 0; i < 2; i++) hourly(t0, 24, rain: (_) => 0),
    ])!;
    final w = RouteWeather([0, 30000], series);
    expect(w.betterDeparture(t0, 3600), isNull);
  });
}

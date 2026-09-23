import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/services/weather_service.dart';

void main() {
  test('Zeitstempel als Unixzeit: Regen in etwa 30 Minuten', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Viertelstunden-Raster ab jetzt; Regen im Intervall, das in 45 min
    // endet (also ab 30 min).
    final times = [for (var i = 0; i < 8; i++) now + i * 900];
    final prec = [0.0, 0.0, 0.0, 0.8, 0.0, 0.0, 0.0, 0.0];
    final w = RideWeather.parse({
      'current': {'temperature_2m': 14.0, 'weather_code': 3},
      'minutely_15': {'time': times, 'precipitation': prec},
      'hourly': {
        'time': [for (var i = 0; i < 10; i++) now + i * 3600],
        'precipitation_probability': [for (var i = 0; i < 10; i++) 40],
        'temperature_2m': [for (var i = 0; i < 10; i++) 12.0],
        'precipitation': [for (var i = 0; i < 10; i++) 0.0],
      },
    })!;
    expect(w.rainInMinutes, inInclusiveRange(29, 30));
    expect(w.warning, startsWith('REGEN IN'));
  });
}

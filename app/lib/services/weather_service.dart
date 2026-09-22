import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Wetter und Regenwarnung von Open-Meteo.
///
/// Warum Open-Meteo: kein Schluessel, keine Anmeldung, kostenlos fuer
/// nicht-gewerbliche Nutzung. Damit funktioniert die Warnung sofort nach
/// dem Installieren, ohne dass jemand ein Konto anlegen muss.
///
/// Pflicht dabei: Die Datenquelle muss genannt werden (CC BY 4.0).
/// Das passiert in der Anzeige unten am Wetterfeld.
class WeatherService {
  static const String attribution = 'Wetterdaten: Open-Meteo.com (CC BY 4.0)';

  /// Holt das Wetter fuer eine Position. Gibt null zurueck, wenn nichts
  /// zu holen war - die App laeuft dann einfach ohne Wetter weiter.
  static Future<RideWeather?> fetch(double lat, double lon) async {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=${lat.toStringAsFixed(4)}'
      '&longitude=${lon.toStringAsFixed(4)}'
      '&current=temperature_2m,precipitation,weather_code,wind_speed_10m'
      '&hourly=precipitation_probability,precipitation,temperature_2m'
      '&minutely_15=precipitation'
      '&forecast_days=2'
      '&timezone=auto',
    );

    try {
      final res =
          await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(utf8.decode(res.bodyBytes));
      if (data is! Map<String, dynamic>) return null;

      // Open-Meteo antwortet auch bei falschen Parametern mit Code 200
      // und legt den Grund in ein Feld "error". Ohne diese Pruefung
      // wuerde die App still falsche Werte anzeigen.
      if (data['error'] == true) return null;

      return RideWeather._parse(data);
    } catch (_) {
      return null;
    }
  }
}

/// Aufbereitetes Wetter fuer die Anzeige.
class RideWeather {
  RideWeather({
    required this.tempC,
    required this.windKmh,
    required this.code,
    required this.rainInMinutes,
    required this.rainProbNextHours,
    required this.minTempNextHours,
  });

  final double? tempC;
  final double? windKmh;

  /// WMO-Wettercode.
  final int? code;

  /// Minuten bis zum naechsten Regen. null = in der Vorschau kein Regen.
  final int? rainInMinutes;

  /// Hoechste Regenwahrscheinlichkeit in den naechsten Stunden, 0-100.
  final int rainProbNextHours;

  /// Niedrigste Temperatur in den naechsten Stunden.
  final double? minTempNextHours;

  /// Kalte Reifen bauen deutlich weniger Haftung auf, und unter etwa
  /// 3 Grad kommt Glaette in Bruecken- und Waldabschnitten dazu.
  bool get coldTyres => (tempC ?? 99) < 8;
  bool get frostRisk => (minTempNextHours ?? 99) < 3;

  bool get rainSoon => rainInMinutes != null && rainInMinutes! <= 90;

  String get condition {
    final c = code;
    if (c == null) return '–';
    if (c == 0) return 'Klar';
    if (c <= 2) return 'Leicht bewölkt';
    if (c == 3) return 'Bedeckt';
    if (c == 45 || c == 48) return 'Nebel';
    if (c >= 51 && c <= 57) return 'Nieselregen';
    if (c >= 61 && c <= 67) return 'Regen';
    if (c >= 71 && c <= 77) return 'Schnee';
    if (c >= 80 && c <= 82) return 'Schauer';
    if (c >= 85 && c <= 86) return 'Schneeschauer';
    if (c >= 95) return 'Gewitter';
    return '–';
  }

  /// Kurzer Warntext fuer das Cockpit, oder null wenn alles ruhig ist.
  String? get warning {
    if (rainSoon) {
      final m = rainInMinutes!;
      if (m <= 5) return 'REGEN JETZT';
      return 'REGEN IN ${m} MIN';
    }
    if (frostRisk) return 'FROSTGEFAHR';
    if (coldTyres) return 'KALTE REIFEN';
    if (rainProbNextHours >= 60) return 'REGEN MÖGLICH ($rainProbNextHours %)';
    return null;
  }

  // -----------------------------------------------------------------
  static RideWeather? _parse(Map<String, dynamic> d) {
    final now = DateTime.now();

    double? asD(dynamic v) => v is num ? v.toDouble() : null;

    final cur = d['current'];
    double? temp;
    double? wind;
    int? code;
    if (cur is Map) {
      temp = asD(cur['temperature_2m']);
      wind = asD(cur['wind_speed_10m']);
      final wc = cur['weather_code'];
      code = wc is num ? wc.toInt() : null;
    }

    // --- Regen im Viertelstunden-Raster (in Mitteleuropa echte
    //     Modelldaten, sonst interpoliert) ---
    int? rainIn;
    final m15 = d['minutely_15'];
    if (m15 is Map) {
      final times = m15['time'];
      final prec = m15['precipitation'];
      if (times is List && prec is List) {
        for (var i = 0; i < times.length && i < prec.length; i++) {
          final t = _time(times[i]);
          if (t == null || t.isBefore(now)) continue;
          final p = asD(prec[i]) ?? 0;
          if (p >= 0.1) {
            rainIn = t.difference(now).inMinutes;
            if (rainIn < 0) rainIn = 0;
            break;
          }
        }
      }
    }

    // --- Stundenwerte: Wahrscheinlichkeit und Tiefsttemperatur ---
    // Achtung: Die Listen beginnen um Mitternacht, nicht bei der
    // aktuellen Stunde. Deshalb wird der passende Index gesucht.
    var maxProb = 0;
    double? minTemp;
    final hourly = d['hourly'];
    if (hourly is Map) {
      final times = hourly['time'];
      final probs = hourly['precipitation_probability'];
      final temps = hourly['temperature_2m'];
      final prec = hourly['precipitation'];
      if (times is List) {
        var counted = 0;
        for (var i = 0; i < times.length; i++) {
          final t = _time(times[i]);
          if (t == null) continue;
          // Die laufende Stunde zaehlt mit, deshalb eine Stunde Puffer.
          if (t.isBefore(now.subtract(const Duration(hours: 1)))) continue;
          if (counted >= 8) break; // naechste 8 Stunden betrachten
          counted++;

          if (probs is List && i < probs.length) {
            final p = asD(probs[i]);
            if (p != null && p.round() > maxProb) maxProb = p.round();
          }
          if (temps is List && i < temps.length) {
            final v = asD(temps[i]);
            if (v != null && (minTemp == null || v < minTemp!)) minTemp = v;
          }
          // Ersatz, falls es keine Viertelstundenwerte gab.
          if (rainIn == null && prec is List && i < prec.length) {
            final p = asD(prec[i]) ?? 0;
            if (p >= 0.2 && t.isAfter(now)) {
              rainIn = t.difference(now).inMinutes;
            }
          }
        }
      }
    }

    if (temp == null && code == null && maxProb == 0) return null;

    return RideWeather(
      tempC: temp,
      windKmh: wind,
      code: code,
      rainInMinutes: rainIn,
      rainProbNextHours: maxProb,
      minTempNextHours: minTemp,
    );
  }

  static DateTime? _time(dynamic v) {
    if (v is! String) return null;
    try {
      // Mit timezone=auto liefert Open-Meteo Ortszeit ohne Zeitzonenangabe.
      // DateTime.parse legt das als lokale Zeit aus - genau richtig, weil
      // auch DateTime.now() lokal ist.
      return DateTime.parse(v);
    } catch (_) {
      return null;
    }
  }
}

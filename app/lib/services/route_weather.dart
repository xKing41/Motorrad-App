import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  WETTER ENTLANG DER ROUTE
//
//  Das Wetter am Start sagt wenig ueber eine 300-km-Tour: Nach drei
//  Stunden ist man 200 km weiter und vielleicht auf 1.800 m. Deshalb wird
//  die Route in Abschnitte geteilt und fuer jeden Abschnitt die Vorhersage
//  ZU DER UHRZEIT gelesen, zu der man dort ankommt ("Regen ab km 140
//  gegen 15:30"). Aus denselben Daten wird auch gerechnet, ob eine
//  spaetere Abfahrt trocken bliebe.
//
//  Quelle: Open-Meteo (kostenlos, ohne Schluessel, CC BY 4.0). Die
//  Hoehe beruecksichtigt Open-Meteo selbst (Gelaendemodell) - Passhoehen
//  werden also kaelter gerechnet als das Tal.
// ---------------------------------------------------------------------------

/// Stuendliche Vorhersage an einem Ort.
class HourlySeries {
  HourlySeries({
    required this.time,
    required this.rainMm,
    required this.prob,
    required this.tempC,
    required this.gustKmh,
    required this.code,
  });

  /// Zeitstempel; der Wert gilt fuer die Stunde DAVOR (Open-Meteo).
  final List<DateTime> time;
  final List<double?> rainMm;
  final List<double?> prob;
  final List<double?> tempC;
  final List<double?> gustKmh;
  final List<int?> code;

  /// Index der Stunde, in die [t] faellt (der erste Zeitstempel NACH
  /// [t] - dessen Wert beschreibt die Stunde, in der man faehrt), oder
  /// -1 ausserhalb der Vorhersage.
  int indexAt(DateTime t) {
    for (var i = 0; i < time.length; i++) {
      if (time[i].isAfter(t)) {
        // Erste Stunde: nur, wenn t hoechstens eine Stunde davor liegt.
        if (i == 0 && time[0].difference(t).inMinutes > 60) return -1;
        return i;
      }
    }
    return -1;
  }
}

/// Wetter an einer Stelle der Route zur Ankunftszeit.
class RouteWeatherPoint {
  const RouteWeatherPoint({
    required this.alongM,
    required this.eta,
    this.tempC,
    this.rainMm = 0,
    this.prob = 0,
    this.gustKmh,
    this.code,
  });

  final double alongM;
  final DateTime eta;
  final double? tempC;
  final double rainMm;
  final double prob;
  final double? gustKmh;
  final int? code;

  bool get thunder => (code ?? 0) >= 95;

  /// Nass: messbarer Regen, oder wahrscheinlicher leichter Regen.
  bool get wet =>
      rainMm >= 0.3 || (rainMm >= 0.1 && prob >= 50) || thunder ||
      ((code ?? 0) >= 61 && (code ?? 0) <= 82 && prob >= 50);
}

/// Auswertung fuer eine Abfahrtszeit.
class RouteWeatherReport {
  RouteWeatherReport(this.departure, this.points);

  final DateTime departure;
  final List<RouteWeatherPoint> points;

  RouteWeatherPoint? get firstWet {
    for (final p in points) {
      if (p.wet) return p;
    }
    return null;
  }

  /// Anteil der Strecke im Nassen (0..1).
  double get wetShare =>
      points.isEmpty ? 0 : points.where((p) => p.wet).length / points.length;

  bool get dry => firstWet == null;
  bool get thunder => points.any((p) => p.thunder);

  double? get minTemp => _min(points.map((p) => p.tempC));
  double? get maxTemp => _max(points.map((p) => p.tempC));
  double? get maxGust => _max(points.map((p) => p.gustKmh));

  static double? _min(Iterable<double?> v) {
    double? m;
    for (final x in v) {
      if (x != null && (m == null || x < m)) m = x;
    }
    return m;
  }

  static double? _max(Iterable<double?> v) {
    double? m;
    for (final x in v) {
      if (x != null && (m == null || x > m)) m = x;
    }
    return m;
  }

  /// Bewertung fuer den Vergleich von Abfahrtszeiten (kleiner = besser).
  double get badness {
    var b = wetShare * 10;
    if (thunder) b += 8;
    final g = maxGust ?? 0;
    if (g >= 60) b += (g - 60) / 10;
    final t = minTemp ?? 15;
    if (t < 8) b += (8 - t) / 3;
    return b;
  }

  /// Warnungen in Klartext, wichtigste zuerst. Leer = keine Bedenken.
  List<String> warnings() {
    final out = <String>[];
    final w = firstWet;
    if (w != null) {
      final start = w.alongM < 1000;
      // Wieder trocken danach?
      RouteWeatherPoint? dryAgain;
      var seen = false;
      for (final p in points) {
        if (identical(p, w)) seen = true;
        if (seen && !p.wet) {
          dryAgain = p;
          break;
        }
      }
      final what = points.any((p) => p.thunder) ? 'Gewitter' : 'Regen';
      final where = start
          ? '$what schon am Start'
          : '$what ab km ${km(w.alongM)} (gegen ${clock(w.eta)})';
      out.add(dryAgain != null
          ? '$where, ab km ${km(dryAgain.alongM)} wieder trocken'
          : where);
    }
    final t = points
        .where((p) => p.tempC != null)
        .fold<RouteWeatherPoint?>(
            null, (m, p) => m == null || p.tempC! < m.tempC! ? p : m);
    if (t != null && t.tempC! < 8) {
      out.add(t.tempC! < 3
          ? 'Frostgefahr: ${t.tempC!.round()} °C bei km ${km(t.alongM)}'
          : 'Kalt: ${t.tempC!.round()} °C bei km ${km(t.alongM)} - '
              'Reifen brauchen länger');
    }
    final g = points
        .where((p) => p.gustKmh != null)
        .fold<RouteWeatherPoint?>(
            null, (m, p) => m == null || p.gustKmh! > m.gustKmh! ? p : m);
    if (g != null && g.gustKmh! >= 60) {
      out.add('Böen bis ${g.gustKmh!.round()} km/h bei km ${km(g.alongM)}');
    }
    return out;
  }

  /// Einzeilige Zusammenfassung.
  String summary() {
    final w = warnings();
    if (w.isNotEmpty) return w.first;
    final lo = minTemp, hi = maxTemp;
    final temps = lo == null
        ? ''
        : (hi == null || hi.round() == lo.round()
            ? ', ${lo.round()} °C'
            : ', ${lo.round()}–${hi.round()} °C');
    return 'Trocken auf der ganzen Strecke$temps';
  }

  static String km(double m) => '${(m / 1000).round()}';
  static String clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class RouteWeather {
  RouteWeather(this.samples, this.series);

  /// Stellen entlang der Route (m ab Start) mit ihrer Vorhersage.
  final List<double> samples;
  final List<HourlySeries> series;

  static const String attribution = 'Wetterdaten: Open-Meteo.com (CC BY 4.0)';

  /// Stellen, fuer die Wetter geholt wird: Start, alle [stepM] und Ziel,
  /// hoechstens [max] Stueck.
  static List<(RoutePoint, double)> samplePoints(List<RoutePoint> pts,
      {double stepM = 20000, int max = 30, double fromM = 0}) {
    if (pts.isEmpty) return const [];
    final cum = cumulativeDistances(pts);
    final total = cum.last;
    final a = fromM.clamp(0.0, total);
    final len = total - a;
    // Kleine Ueberlaenge (100,02 km) soll keinen Extra-Punkt ergeben.
    final n = math.min(max - 1, math.max(1, (len / stepM - 0.05).ceil()));
    return [
      for (var i = 0; i <= n; i++)
        (pointAlong(pts, cum, a + len * i / n), a + len * i / n),
    ];
  }

  /// Holt die Vorhersage fuer die Route (ab [fromM]). null = kein Netz.
  static Future<RouteWeather?> fetch(List<RoutePoint> pts,
      {double fromM = 0, http.Client? client}) async {
    final s = samplePoints(pts, fromM: fromM);
    if (s.isEmpty) return null;
    final uri = Uri.parse('https://api.open-meteo.com/v1/forecast'
        '?latitude=${s.map((e) => e.$1.lat.toStringAsFixed(3)).join(',')}'
        '&longitude=${s.map((e) => e.$1.lon.toStringAsFixed(3)).join(',')}'
        '&hourly=precipitation,precipitation_probability,temperature_2m,'
        'wind_gusts_10m,weather_code'
        '&forecast_days=3&timeformat=unixtime&timezone=GMT');
    try {
      final res = await (client?.get(uri) ?? http.get(uri))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final series = parseMulti(data);
      if (series == null || series.length != s.length) return null;
      return RouteWeather([for (final e in s) e.$2], series);
    } catch (_) {
      return null;
    }
  }

  /// Liest die Antwort (eine Liste bei mehreren Orten, sonst ein Objekt).
  static List<HourlySeries>? parseMulti(Object? data) {
    final list = data is List ? data : [data];
    final out = <HourlySeries>[];
    for (final d in list) {
      if (d is! Map || d['error'] == true) return null;
      final h = d['hourly'];
      if (h is! Map || h['time'] is! List) return null;
      final times = [
        for (final t in h['time'] as List)
          if (t is num)
            DateTime.fromMillisecondsSinceEpoch((t * 1000).round())
          else
            DateTime.tryParse('$t') ?? DateTime(1970),
      ];
      List<double?> nums(String k) {
        final v = h[k];
        return [
          for (var i = 0; i < times.length; i++)
            v is List && i < v.length && v[i] is num
                ? (v[i] as num).toDouble()
                : null,
        ];
      }

      out.add(HourlySeries(
        time: times,
        rainMm: nums('precipitation'),
        prob: nums('precipitation_probability'),
        tempC: nums('temperature_2m'),
        gustKmh: nums('wind_gusts_10m'),
        code: [for (final c in nums('weather_code')) c?.round()],
      ));
    }
    return out;
  }

  /// Wetter an jeder Stelle zur Ankunftszeit, Abfahrt um [departure].
  /// Die Fahrzeit wird gleichmaessig ueber die Strecke verteilt.
  RouteWeatherReport at(DateTime departure, int durationSec) {
    final points = <RouteWeatherPoint>[];
    if (samples.isEmpty) return RouteWeatherReport(departure, points);
    final a = samples.first, len = samples.last - a;
    for (var i = 0; i < samples.length; i++) {
      final share = len > 0 ? (samples[i] - a) / len : 0.0;
      final eta =
          departure.add(Duration(seconds: (durationSec * share).round()));
      final s = series[i];
      final k = s.indexAt(eta);
      if (k < 0) continue; // ausserhalb der Vorhersage
      points.add(RouteWeatherPoint(
        alongM: samples[i],
        eta: eta,
        tempC: s.tempC[k],
        rainMm: s.rainMm[k] ?? 0,
        prob: s.prob[k] ?? 0,
        gustKmh: s.gustKmh[k],
        code: s.code[k],
      ));
    }
    return RouteWeatherReport(departure, points);
  }

  /// Beste Abfahrt in den naechsten [hours] Stunden (volle Stunden),
  /// wenn sie deutlich besser ist als jetzt - sonst null.
  RouteWeatherReport? betterDeparture(DateTime now, int durationSec,
      {int hours = 8}) {
    final base = at(now, durationSec);
    if (base.badness < 0.5) return null;
    RouteWeatherReport? best;
    final first = DateTime(now.year, now.month, now.day, now.hour)
        .add(const Duration(hours: 1));
    for (var h = 0; h < hours; h++) {
      final dep = first.add(Duration(hours: h));
      final r = at(dep, durationSec);
      // Nur wenn die ganze Strecke abgedeckt ist.
      if (r.points.length < samples.length) break;
      if (best == null || r.badness < best.badness - 0.01) best = r;
    }
    if (best == null || best.badness > base.badness * 0.5) return null;
    return best;
  }
}

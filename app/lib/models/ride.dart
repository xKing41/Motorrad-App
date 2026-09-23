import 'dart:math' as math;

/// Ein einzelner aufgezeichneter Punkt der Fahrt.
/// Bewusst kompakt gehalten (kurze JSON-Keys), damit lange Touren
/// nicht unnoetig viel Speicher belegen.
class TrackPoint {
  TrackPoint({
    required this.lat,
    required this.lon,
    required this.tMs,
    required this.speedMs,
    required this.lean,
    this.altM,
    this.latG,
    this.longG,
  });

  final double lat;
  final double lon;
  final int tMs; // Zeitstempel in Millisekunden seit Epoch
  final double speedMs; // Geschwindigkeit in m/s
  final double lean; // Schraeglage in Grad, + = rechts
  final double? altM;

  /// Gemessene Quer- und Laengsbeschleunigung in g (ab Version 4.5;
  /// aeltere Fahrten haben sie nicht).
  final double? latG;
  final double? longG;

  Map<String, dynamic> toJson() => {
        'a': double.parse(lat.toStringAsFixed(6)),
        'o': double.parse(lon.toStringAsFixed(6)),
        't': tMs,
        's': double.parse(speedMs.toStringAsFixed(2)),
        'l': double.parse(lean.toStringAsFixed(1)),
        if (altM != null) 'h': double.parse(altM!.toStringAsFixed(1)),
        if (latG != null) 'g': double.parse(latG!.toStringAsFixed(2)),
        if (longG != null) 'x': double.parse(longG!.toStringAsFixed(2)),
      };

  static TrackPoint fromJson(Map<String, dynamic> j) => TrackPoint(
        lat: (j['a'] as num).toDouble(),
        lon: (j['o'] as num).toDouble(),
        tMs: (j['t'] as num).toInt(),
        speedMs: (j['s'] as num?)?.toDouble() ?? 0,
        lean: (j['l'] as num?)?.toDouble() ?? 0,
        altM: (j['h'] as num?)?.toDouble(),
        latG: (j['g'] as num?)?.toDouble(),
        longG: (j['x'] as num?)?.toDouble(),
      );
}

/// Zusammenfassung einer Fahrt. Wird im Index gehalten, damit die
/// Fahrtenliste schnell laedt, ohne alle Trackpunkte zu lesen.
class RideSummary {
  RideSummary({
    required this.id,
    required this.start,
    required this.durationSec,
    required this.distanceM,
    required this.maxLeanL,
    required this.maxLeanR,
    required this.maxSpeedMs,
    required this.maxBrakeG,
    required this.maxLatG,
    required this.pointCount,
    this.title,
    this.movingSec,
  });

  final String id;
  final DateTime start;
  final int durationSec;
  final double distanceM;
  final double maxLeanL; // positiver Betrag
  final double maxLeanR;
  final double maxSpeedMs;
  final double maxBrakeG;
  final double maxLatG;
  final int pointCount;
  final String? title;

  /// Reine Fahrzeit ohne Stillstand (null bei alten Fahrten).
  final int? movingSec;

  double get distanceKm => distanceM / 1000;
  double get maxSpeedKmh => maxSpeedMs * 3.6;

  /// Durchschnitt in Fahrt - Pausen an der Tankstelle oder im Cafe
  /// zaehlen nicht mit (vorher: 60 km in 2 h mit 1 h Pause = "30 km/h").
  double get avgSpeedKmh {
    final t = (movingSec != null && movingSec! > 0) ? movingSec! : durationSec;
    return t > 0 ? distanceKm / (t / 3600) : 0;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'start': start.millisecondsSinceEpoch,
        'dur': durationSec,
        'dist': distanceM.round(),
        'maxL': double.parse(maxLeanL.toStringAsFixed(1)),
        'maxR': double.parse(maxLeanR.toStringAsFixed(1)),
        'vmax': double.parse(maxSpeedMs.toStringAsFixed(2)),
        'brake': double.parse(maxBrakeG.toStringAsFixed(2)),
        'lat': double.parse(maxLatG.toStringAsFixed(2)),
        'n': pointCount,
        if (title != null) 'title': title,
        if (movingSec != null) 'mov': movingSec,
      };

  static RideSummary fromJson(Map<String, dynamic> j) => RideSummary(
        id: j['id'] as String,
        start: DateTime.fromMillisecondsSinceEpoch((j['start'] as num).toInt()),
        durationSec: (j['dur'] as num?)?.toInt() ?? 0,
        distanceM: (j['dist'] as num?)?.toDouble() ?? 0,
        maxLeanL: (j['maxL'] as num?)?.toDouble() ?? 0,
        maxLeanR: (j['maxR'] as num?)?.toDouble() ?? 0,
        maxSpeedMs: (j['vmax'] as num?)?.toDouble() ?? 0,
        maxBrakeG: (j['brake'] as num?)?.toDouble() ?? 0,
        maxLatG: (j['lat'] as num?)?.toDouble() ?? 0,
        pointCount: (j['n'] as num?)?.toInt() ?? 0,
        title: j['title'] as String?,
        movingSec: (j['mov'] as num?)?.toInt(),
      );
}

/// Eine erkannte Kurve innerhalb einer Fahrt.
/// Basis fuer die spaetere Kurvenanalyse und fuer die KI-Routenplanung
/// ("fahr mich ueber Strassen, auf denen ich gut unterwegs war").
class Corner {
  Corner({
    required this.startIndex,
    required this.endIndex,
    required this.maxLean,
    required this.direction,
    required this.entrySpeedKmh,
    required this.minSpeedKmh,
    required this.exitSpeedKmh,
    required this.lat,
    required this.lon,
    this.apexSpeedKmh = 0,
    this.apexLatG,
  });

  final int startIndex;
  final int endIndex;
  final double maxLean; // Betrag in Grad
  final int direction; // -1 = links, +1 = rechts
  final double entrySpeedKmh;
  final double minSpeedKmh;
  final double exitSpeedKmh;
  final double lat; // Scheitelpunkt
  final double lon;

  /// Tempo am Scheitel (Punkt der groessten Schraeglage).
  final double apexSpeedKmh;

  /// Gemessene Querbeschleunigung am Scheitel (null bei alten Fahrten).
  final double? apexLatG;

  Map<String, dynamic> toJson() => {
        'i0': startIndex,
        'i1': endIndex,
        'lean': double.parse(maxLean.toStringAsFixed(1)),
        'dir': direction,
        'vIn': entrySpeedKmh.round(),
        'vMin': minSpeedKmh.round(),
        'vOut': exitSpeedKmh.round(),
        'a': double.parse(lat.toStringAsFixed(6)),
        'o': double.parse(lon.toStringAsFixed(6)),
      };
}

/// Unter diesem Tempo zaehlt Schraeglage nicht als Kurve: Im Stand ist
/// es der Seitenstaender oder das Abstuetzen an der Ampel.
const double cornerMinSpeedMs = 3; // ~11 km/h

/// Erkennt Kurven in einem Track: zusammenhaengende Abschnitte, in denen
/// die Schraeglage einen Schwellwert ueberschreitet.
List<Corner> detectCorners(List<TrackPoint> track, {double minLean = 12}) {
  final out = <Corner>[];
  int? startIdx;
  int dir = 0;

  for (var i = 0; i < track.length; i++) {
    final lean = track[i].lean;
    // Vorher wurde jedes Parken auf dem Seitenstaender (rund 12-15 Grad
    // links) als Linkskurve gezaehlt.
    final abs = track[i].speedMs >= cornerMinSpeedMs ? lean.abs() : 0.0;
    final d = lean < 0 ? -1 : 1;

    if (abs >= minLean) {
      if (startIdx == null) {
        startIdx = i;
        dir = d;
      } else if (d != dir) {
        // Richtungswechsel: alte Kurve abschliessen, neue beginnen
        _addCorner(out, track, startIdx, i - 1, dir);
        startIdx = i;
        dir = d;
      }
    } else if (startIdx != null) {
      _addCorner(out, track, startIdx, i - 1, dir);
      startIdx = null;
    }
  }
  if (startIdx != null) {
    _addCorner(out, track, startIdx, track.length - 1, dir);
  }
  return out;
}

void _addCorner(
    List<Corner> out, List<TrackPoint> track, int i0, int i1, int dir) {
  if (i1 <= i0) return;
  double maxLean = 0;
  int apex = i0;
  double vMin = double.infinity;
  for (var i = i0; i <= i1; i++) {
    final a = track[i].lean.abs();
    if (a > maxLean) {
      maxLean = a;
      apex = i;
    }
    final v = track[i].speedMs * 3.6;
    if (v < vMin) vMin = v;
  }
  if (maxLean < 12) return;
  out.add(Corner(
    startIndex: i0,
    endIndex: i1,
    maxLean: maxLean,
    direction: dir,
    entrySpeedKmh: track[i0].speedMs * 3.6,
    minSpeedKmh: vMin.isFinite ? vMin : 0,
    exitSpeedKmh: track[i1].speedMs * 3.6,
    lat: track[apex].lat,
    lon: track[apex].lon,
    apexSpeedKmh: track[apex].speedMs * 3.6,
    apexLatG: track[apex].latG,
  ));
}

/// Rasterzelle fuer die Karte der eigenen Strecken (~110 x 70 m).
/// Planer und Fahrtenspeicher muessen dieselbe Rechnung nutzen.
String heatCellKey(double lat, double lon) =>
    '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}';

/// Entfernung zweier Koordinaten in Metern (Haversine).
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

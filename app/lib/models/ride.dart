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
  });

  final double lat;
  final double lon;
  final int tMs; // Zeitstempel in Millisekunden seit Epoch
  final double speedMs; // Geschwindigkeit in m/s
  final double lean; // Schraeglage in Grad, + = rechts
  final double? altM;

  Map<String, dynamic> toJson() => {
        'a': double.parse(lat.toStringAsFixed(6)),
        'o': double.parse(lon.toStringAsFixed(6)),
        't': tMs,
        's': double.parse(speedMs.toStringAsFixed(2)),
        'l': double.parse(lean.toStringAsFixed(1)),
        if (altM != null) 'h': double.parse(altM!.toStringAsFixed(1)),
      };

  static TrackPoint fromJson(Map<String, dynamic> j) => TrackPoint(
        lat: (j['a'] as num).toDouble(),
        lon: (j['o'] as num).toDouble(),
        tMs: (j['t'] as num).toInt(),
        speedMs: (j['s'] as num?)?.toDouble() ?? 0,
        lean: (j['l'] as num?)?.toDouble() ?? 0,
        altM: (j['h'] as num?)?.toDouble(),
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

  double get distanceKm => distanceM / 1000;
  double get maxSpeedKmh => maxSpeedMs * 3.6;
  double get avgSpeedKmh =>
      durationSec > 0 ? distanceKm / (durationSec / 3600) : 0;

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

/// Erkennt Kurven in einem Track: zusammenhaengende Abschnitte, in denen
/// die Schraeglage einen Schwellwert ueberschreitet.
List<Corner> detectCorners(List<TrackPoint> track, {double minLean = 12}) {
  final out = <Corner>[];
  int? startIdx;
  int dir = 0;

  for (var i = 0; i < track.length; i++) {
    final lean = track[i].lean;
    final abs = lean.abs();
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
  ));
}

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

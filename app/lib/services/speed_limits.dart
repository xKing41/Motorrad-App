import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  TEMPOLIMITS ENTLANG DER ROUTE
//
//  Die Tempolimits stehen in OpenStreetMap (maxspeed) - kostenlos. Der
//  Valhalla-Server der FOSSGIS legt die Route auf die Strassen
//  ("trace_attributes") und liefert je Strassenstueck das Limit. Das
//  passiert einmal beim Planen; danach liegen die Limits im Speicher und
//  funktionieren auch im Funkloch.
//
//  Grenzen: OSM kennt fast alle Limits auf Autobahnen und Bundesstrassen,
//  auf kleinen Landstrassen fehlen manche - dann zeigt die App nichts an
//  statt zu raten. Wechselverkehrszeichen und zeitliche Limits (nachts,
//  bei Naesse) kennt keine freie Quelle.
// ---------------------------------------------------------------------------

/// Tempolimit auf einem Stueck der Route (m ab Start).
class SpeedLimit {
  const SpeedLimit(this.fromM, this.toM, this.kmh);
  final double fromM;
  final double toM;

  /// km/h; [unlimited] = kein Limit (deutsche Autobahn).
  final int kmh;

  static const int unlimited = 999;
  bool get isUnlimited => kmh >= unlimited;

  @override
  String toString() => 'SpeedLimit($fromM-$toM: $kmh)';
}

/// Liefert die Tempolimits fuer eine Route.
abstract class SpeedLimitSource {
  Future<List<SpeedLimit>> forRoute(List<RoutePoint> pts);
}

/// Limit an der Stelle [alongM], null = unbekannt.
SpeedLimit? limitAt(List<SpeedLimit> limits, double alongM) {
  var lo = 0, hi = limits.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final l = limits[mid];
    if (alongM < l.fromM) {
      hi = mid - 1;
    } else if (alongM >= l.toM) {
      lo = mid + 1;
    } else {
      return l;
    }
  }
  return null;
}

/// Naechster Wechsel des Limits voraus (fuer "gleich 70").
SpeedLimit? nextChange(List<SpeedLimit> limits, double alongM,
    {double withinM = 400}) {
  final cur = limitAt(limits, alongM);
  for (final l in limits) {
    if (l.fromM <= alongM) continue;
    if (l.fromM > alongM + withinM) break;
    if (cur == null || l.kmh != cur.kmh) return l;
  }
  return null;
}

class ValhallaSpeedLimits implements SpeedLimitSource {
  ValhallaSpeedLimits({
    this.base = 'https://valhalla1.openstreetmap.de',
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
  }) : _client = client;

  static final ValhallaSpeedLimits instance = ValhallaSpeedLimits();
  static final Map<String, ValhallaSpeedLimits> _byBase = {};

  /// Eigener Valhalla-Server (eine Instanz je Adresse, wegen des
  /// Zwischenspeichers).
  static ValhallaSpeedLimits forBase(String url) {
    var b = url.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return _byBase.putIfAbsent(b, () => ValhallaSpeedLimits(base: b));
  }

  final String base;
  final http.Client? _client;
  final Duration timeout;

  /// Stueckgroesse fuer eine Anfrage (Grenzen des Servers).
  static const double chunkM = 50000;
  static const int chunkMaxPoints = 2500;

  // Ergebnis je Route (die Punktliste selbst ist der Schluessel).
  final Map<List<RoutePoint>, Future<List<SpeedLimit>>> _cache =
      LinkedHashMap.identity();

  @override
  Future<List<SpeedLimit>> forRoute(List<RoutePoint> pts) {
    final hit = _cache[pts];
    if (hit != null) return hit;
    final f = _fetch(pts);
    _cache[pts] = f;
    // Nur die letzten Routen behalten.
    while (_cache.length > 6) {
      _cache.remove(_cache.keys.first);
    }
    // Ganz fehlgeschlagen (kein Netz): beim naechsten Mal neu versuchen.
    f.then((l) {
      if (l.isEmpty) _cache.remove(pts);
    }, onError: (_) {
      _cache.remove(pts);
    });
    return f;
  }

  Future<List<SpeedLimit>> _fetch(List<RoutePoint> pts) async {
    if (pts.length < 2) return const [];
    final cum = cumulativeDistances(pts);
    final out = <SpeedLimit>[];
    for (final (a, b) in chunks(cum)) {
      final part = pts.sublist(a, b + 1);
      try {
        final json = await _post(part);
        out.addAll(parse(json, cum[a], cum[b] - cum[a]));
      } catch (_) {
        // Stueck bleibt ohne Limit - lieber nichts anzeigen als raten.
      }
    }
    return merge(out);
  }

  /// Teilt die Route in Stuecke (Index von/bis, ueberlappend am Rand).
  static List<(int, int)> chunks(List<double> cum) {
    final out = <(int, int)>[];
    var a = 0;
    while (a < cum.length - 1) {
      var b = a + 1;
      while (b < cum.length - 1 &&
          cum[b + 1] - cum[a] <= chunkM &&
          b + 1 - a < chunkMaxPoints) {
        b++;
      }
      out.add((a, b));
      a = b;
    }
    return out;
  }

  Future<Map<String, dynamic>> _post(List<RoutePoint> part) async {
    final body = jsonEncode({
      'encoded_polyline': encodePolyline(part),
      'shape_match': 'walk_or_snap',
      // Zum Zuordnen reicht das Auto-Profil; es ist am robustesten.
      'costing': 'auto',
      'filters': {
        'attributes': [
          'edge.speed_limit',
          'edge.begin_shape_index',
          'edge.end_shape_index',
          'shape',
        ],
        'action': 'include',
      },
    });
    final uri = Uri.parse('$base/trace_attributes');
    const headers = {
      'Content-Type': 'application/json',
      'User-Agent': 'Schraeglage/4.15 (Motorrad-App)',
    };
    final c = _client;
    final res = await (c != null
            ? c.post(uri, headers: headers, body: body)
            : http.post(uri, headers: headers, body: body))
        .timeout(timeout);
    if (res.statusCode != 200) {
      throw http.ClientException('trace_attributes ${res.statusCode}', uri);
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! Map<String, dynamic>) throw const FormatException();
    return data;
  }

  /// Liest die Antwort. Die Kanten verweisen auf Punkte der vom Server
  /// zurueckgegebenen (auf die Strasse gelegten) Linie; deren Laenge
  /// wird auf das eigene Routenstueck umgerechnet.
  static List<SpeedLimit> parse(
      Map<String, dynamic> j, double startM, double lengthM) {
    final edges = (j['edges'] as List?) ?? const [];
    final shapeEnc = j['shape'];
    if (edges.isEmpty || shapeEnc is! String) return const [];
    final shape = decodePolyline(shapeEnc);
    if (shape.length < 2) return const [];
    final cum = cumulativeDistances(shape);
    final scale = cum.last > 0 ? lengthM / cum.last : 1.0;
    final out = <SpeedLimit>[];
    for (final e in edges.whereType<Map<String, dynamic>>()) {
      final kmh = parseLimit(e['speed_limit'], j['units']);
      final bi = (e['begin_shape_index'] as num?)?.toInt();
      final ei = (e['end_shape_index'] as num?)?.toInt();
      if (kmh == null || bi == null || ei == null) continue;
      final a = cum[bi.clamp(0, cum.length - 1)];
      final b = cum[ei.clamp(0, cum.length - 1)];
      if (b <= a) continue;
      out.add(SpeedLimit(startM + a * scale, startM + b * scale, kmh));
    }
    return out;
  }

  /// Wert aus der Antwort: Zahl (km/h oder mph je nach [units]) oder
  /// "unlimited". 0 und Unsinn = unbekannt.
  static int? parseLimit(Object? v, Object? units) {
    if (v is String) {
      if (v.toLowerCase() == 'unlimited') return SpeedLimit.unlimited;
      v = num.tryParse(v);
    }
    if (v is! num || v <= 0) return null;
    var kmh = v.toDouble();
    if (units is String && units.startsWith('mi')) kmh *= 1.609344;
    if (kmh >= 250) return SpeedLimit.unlimited;
    if (kmh < 5) return null;
    return kmh.round();
  }

  /// Fasst aneinandergrenzende Stuecke mit gleichem Limit zusammen und
  /// sortiert. Kleine Luecken (< 30 m, Kreuzungen) werden geschlossen.
  static List<SpeedLimit> merge(List<SpeedLimit> l) {
    if (l.isEmpty) return const [];
    final s = [...l]..sort((a, b) => a.fromM.compareTo(b.fromM));
    final out = <SpeedLimit>[s.first];
    for (final x in s.skip(1)) {
      final last = out.last;
      if (x.fromM < last.toM) {
        // Ueberlappung am Stueckrand: das neue Stueck beginnt danach.
        if (x.toM <= last.toM) continue;
        final cut = SpeedLimit(last.toM, x.toM, x.kmh);
        if (cut.kmh == last.kmh) {
          out[out.length - 1] = SpeedLimit(last.fromM, x.toM, last.kmh);
        } else {
          out.add(cut);
        }
        continue;
      }
      if (x.kmh == last.kmh && x.fromM - last.toM < 30) {
        out[out.length - 1] = SpeedLimit(last.fromM, x.toM, last.kmh);
      } else {
        out.add(x);
      }
    }
    return out;
  }

  /// Anteil der Route mit bekanntem Limit (0..1) - fuer die Anzeige.
  static double coverage(List<SpeedLimit> l, double totalM) {
    if (totalM <= 0) return 0;
    final known = l.fold<double>(0, (s, x) => s + (x.toM - x.fromM));
    return math.min(1, known / totalM);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/route_plan.dart';
import 'geo.dart';
import 'traffic_service.dart';

// ---------------------------------------------------------------------------
//  WEITERE VERKEHRSQUELLEN
//
//  Keine Quelle weiss alles. TomTom ist stark bei Staus (aus den Daten
//  von Millionen Navis), HERE liefert viele Automobilhersteller und hat
//  eigene Meldungen, und die Autobahn GmbH kennt ihre Baustellen und
//  Sperrungen als Erste - amtlich und ohne Schluessel. Zusammen ergibt
//  das das vollstaendigste Bild. Dieselbe Sperrung aus zwei Quellen wird
//  nur einmal gezeigt.
// ---------------------------------------------------------------------------

/// HERE Traffic API v7 (Schluessel von developer.here.com).
class HereTraffic implements TrafficFeed {
  HereTraffic(this.apiKey,
      {http.Client? client, this.timeout = const Duration(seconds: 15)})
      : _client = client;

  final String apiKey;
  final Duration timeout;
  final http.Client? _client;

  @override
  String get label => 'HERE';

  @override
  String? lastError;

  @override
  Future<List<TrafficIncident>?> alongRoute(
    List<RoutePoint> pts, {
    double fromM = 0,
    double? toM,
    int maxBoxes = 25,
    List<RouteStep> steps = const [],
  }) async {
    lastError = null;
    if (pts.length < 2) return const [];
    final cum = cumulativeDistances(pts);
    final end = math.min(toM ?? cum.last, cum.last);
    final boxes =
        TrafficService.routeBoxes(pts, cum, fromM, end, maxBoxes: maxBoxes);
    final raw = <TrafficIncident>[];
    final seen = <String>{};
    var failed = 0;
    for (final b in boxes) {
      final uri = Uri.https('data.traffic.hereapi.com', '/v7/incidents', {
        'in': 'bbox:${b.$2},${b.$1},${b.$4},${b.$3}',
        'locationReferencing': 'shape',
        'lang': 'de-DE',
        'apiKey': apiKey.trim(),
      });
      try {
        final c = _client;
        final res =
            await (c != null ? c.get(uri) : http.get(uri)).timeout(timeout);
        if (res.statusCode == 401 || res.statusCode == 403) {
          lastError = TrafficKeyException('HERE').toString();
          return null;
        }
        if (res.statusCode != 200) {
          failed++;
          continue;
        }
        for (final i in parse(jsonDecode(utf8.decode(res.bodyBytes)))) {
          if (seen.add(i.id)) raw.add(i);
        }
      } catch (_) {
        failed++;
      }
    }
    if (boxes.isNotEmpty && failed == boxes.length) return null;
    return TrafficService.matchToRoute(raw, pts, cum, fromM: fromM, toM: end);
  }

  /// Wertet eine Antwort der Incidents-API aus.
  static List<TrafficIncident> parse(dynamic data) {
    if (data is! Map) return const [];
    final out = <TrafficIncident>[];
    for (final r in (data['results'] as List?) ?? const []) {
      if (r is! Map) continue;
      final details = (r['incidentDetails'] as Map?) ?? const {};
      final loc = (r['location'] as Map?) ?? const {};
      final links = ((loc['shape'] as Map?)?['links'] as List?) ?? const [];
      final pts = <RoutePoint>[];
      for (final l in links) {
        if (l is! Map) continue;
        for (final p in (l['points'] as List?) ?? const []) {
          if (p is Map && p['lat'] is num && p['lng'] is num) {
            pts.add(RoutePoint(
                (p['lat'] as num).toDouble(), (p['lng'] as num).toDouble()));
          }
        }
      }
      if (pts.isEmpty) continue;
      final type = '${details['type'] ?? ''}';
      final closed = details['roadClosed'] == true;
      final desc = ((details['description'] as Map?)?['value'] ??
              (details['summary'] as Map?)?['value'])
          ?.toString();
      out.add(TrafficIncident(
        id: 'here_${details['id'] ?? out.length}',
        category: closed ? TrafficCategory.closed : categoryOf(type),
        points: pts,
        description: (desc == null || desc.isEmpty) ? null : desc,
        magnitude: switch ('${details['criticality'] ?? ''}') {
          'critical' => 4,
          'major' => 3,
          'minor' => 2,
          'low' => 1,
          _ => 0,
        },
        lengthM: (loc['length'] as num?)?.toDouble() ?? pathLength(pts),
        source: 'HERE',
      ));
    }
    return out;
  }

  static TrafficCategory categoryOf(String type) => switch (type) {
        'congestion' => TrafficCategory.jam,
        'roadClosure' => TrafficCategory.closed,
        'construction' => TrafficCategory.roadworks,
        'laneRestriction' => TrafficCategory.laneClosed,
        'accident' => TrafficCategory.accident,
        'disabledVehicle' || 'roadHazard' => TrafficCategory.hazard,
        'weather' => TrafficCategory.weather,
        _ => TrafficCategory.other,
      };
}

/// Amtliche Meldungen der Autobahn GmbH des Bundes (verkehr.autobahn.de):
/// Baustellen, Sperrungen und Warnungen (Stau) auf deutschen Autobahnen.
/// Kostenlos und ohne Schluessel.
class AutobahnTraffic implements TrafficFeed {
  AutobahnTraffic(
      {http.Client? client, this.timeout = const Duration(seconds: 15)})
      : _client = client;

  final Duration timeout;
  final http.Client? _client;

  static const _host = 'verkehr.autobahn.de';

  /// Meldungen je Autobahn, einige Minuten zwischengespeichert.
  static final Map<String, (DateTime, List<TrafficIncident>)> _cache = {};
  static const Duration cacheFor = Duration(minutes: 3);

  @override
  String get label => 'Autobahn GmbH';

  @override
  String? lastError;

  /// Welche Autobahnen die Route befaehrt - aus den Anweisungen
  /// ("... auf A 45 Richtung ..."). Deutsche Autobahnen haben hoechstens
  /// drei Ziffern.
  static Set<String> roadsIn(List<RouteStep> steps) {
    final re = RegExp(r'\bA\s?(\d{1,3})\b');
    return {
      for (final s in steps)
        for (final m in re.allMatches('${s.text} ${s.verbal ?? ''}'))
          'A${int.parse(m.group(1)!)}',
    };
  }

  @override
  Future<List<TrafficIncident>?> alongRoute(
    List<RoutePoint> pts, {
    double fromM = 0,
    double? toM,
    int maxBoxes = 25,
    List<RouteStep> steps = const [],
  }) async {
    lastError = null;
    final roads = roadsIn(steps);
    if (roads.isEmpty || pts.length < 2) return const [];
    final cum = cumulativeDistances(pts);
    final end = math.min(toM ?? cum.last, cum.last);
    final raw = <TrafficIncident>[];
    var failed = 0;
    for (final road in roads) {
      final list = await _road(road);
      if (list == null) {
        failed++;
        continue;
      }
      raw.addAll(list);
    }
    if (failed == roads.length) return null;
    return TrafficService.matchToRoute(raw, pts, cum, fromM: fromM, toM: end);
  }

  Future<List<TrafficIncident>?> _road(String road) async {
    final hit = _cache[road];
    if (hit != null && DateTime.now().difference(hit.$1) < cacheFor) {
      return hit.$2;
    }
    final out = <TrafficIncident>[];
    var ok = false;
    for (final service in const ['closure', 'roadworks', 'warning']) {
      final uri = Uri.https(_host, '/o/autobahn/$road/services/$service');
      try {
        final c = _client;
        final res =
            await (c != null ? c.get(uri) : http.get(uri)).timeout(timeout);
        if (res.statusCode == 404) {
          ok = true; // Diese Autobahn gibt es nicht (z. B. im Ausland).
          continue;
        }
        if (res.statusCode != 200) continue;
        ok = true;
        out.addAll(parse(jsonDecode(utf8.decode(res.bodyBytes)), service, road));
      } catch (_) {
        // naechster Dienst
      }
    }
    if (!ok) return null;
    _cache[road] = (DateTime.now(), out);
    return out;
  }

  /// Wertet eine Antwort aus ([service]: closure, roadworks, warning).
  static List<TrafficIncident> parse(dynamic data, String service, String road) {
    if (data is! Map) return const [];
    final items = (data[service] as List?) ?? const [];
    final out = <TrafficIncident>[];
    for (final it in items) {
      if (it is! Map) continue;
      final pts = <RoutePoint>[];
      final geom = it['geometry'];
      if (geom is Map && geom['coordinates'] is List) {
        for (final c in geom['coordinates'] as List) {
          if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
            pts.add(RoutePoint(
                (c[1] as num).toDouble(), (c[0] as num).toDouble()));
          }
        }
      }
      if (pts.isEmpty) {
        final co = it['coordinate'];
        if (co is Map) {
          final la = double.tryParse('${co['lat']}');
          final lo = double.tryParse('${co['long']}');
          if (la != null && lo != null) pts.add(RoutePoint(la, lo));
        }
      }
      if (pts.isEmpty) continue;
      final blocked = '${it['isBlocked']}' == 'true';
      final category = switch (service) {
        'closure' => TrafficCategory.closed,
        'roadworks' =>
          blocked ? TrafficCategory.closed : TrafficCategory.roadworks,
        _ => TrafficCategory.jam,
      };
      final delayMin = int.tryParse('${it['delayTimeValue'] ?? ''}') ?? 0;
      final descList = (it['description'] as List?)
              ?.whereType<String>()
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList() ??
          const <String>[];
      final title = [it['title'], it['subtitle']]
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .join(' · ');
      out.add(TrafficIncident(
        id: 'ab_${it['identifier'] ?? '${road}_${service}_${out.length}'}',
        category: category,
        points: pts,
        description: [title, if (descList.isNotEmpty) descList.first]
            .where((s) => s.isNotEmpty)
            .join(' · '),
        road: road,
        delaySec: delayMin * 60,
        magnitude: category == TrafficCategory.closed
            ? 4
            : (delayMin >= 15 ? 3 : (delayMin > 0 ? 2 : 0)),
        lengthM: pts.length > 1 ? pathLength(pts) : 0,
        source: 'Autobahn GmbH',
      ));
    }
    return out;
  }
}

/// Fragt alle Quellen ab und fuehrt die Meldungen zusammen.
class TrafficHub implements TrafficFeed {
  TrafficHub(this.feeds);

  final List<TrafficFeed> feeds;

  @override
  String get label => feeds.map((f) => f.label).join(' + ');

  @override
  String? lastError;

  @override
  Future<List<TrafficIncident>?> alongRoute(
    List<RoutePoint> pts, {
    double fromM = 0,
    double? toM,
    int maxBoxes = 25,
    List<RouteStep> steps = const [],
  }) async {
    lastError = null;
    final results = await Future.wait([
      for (final f in feeds)
        () async {
          try {
            final r = await f.alongRoute(pts,
                fromM: fromM, toM: toM, maxBoxes: maxBoxes, steps: steps);
            if (f.lastError != null) lastError ??= f.lastError;
            return r;
          } on TrafficKeyException catch (e) {
            lastError ??= e.toString();
            return null;
          } catch (_) {
            return null;
          }
        }(),
    ]);
    final ok = results.whereType<List<TrafficIncident>>().toList();
    if (ok.isEmpty) return feeds.isEmpty ? const [] : null;
    return merge(ok.expand((l) => l).toList());
  }

  /// Fuehrt Meldungen zusammen, die dasselbe Ereignis beschreiben: gleiche
  /// Art (oder verwandt, z. B. Baustelle und Sperrung) und sie ueberlappen
  /// auf der Route oder liegen hoechstens 300 m auseinander. Behalten wird
  /// die schwerere Meldung; die Quellen werden zusammen genannt und der
  /// groesste bekannte Zeitverlust uebernommen.
  static List<TrafficIncident> merge(List<TrafficIncident> all) {
    int rank(TrafficIncident i) =>
        (i.isClosure ? 100 : 0) + i.magnitude * 10 + (i.delaySec > 0 ? 5 : 0);
    final sorted = [...all]..sort((a, b) => rank(b).compareTo(rank(a)));
    final out = <TrafficIncident>[];
    for (final i in sorted) {
      final idx = out.indexWhere((o) => _same(o, i));
      if (idx < 0) {
        out.add(i);
        continue;
      }
      final o = out[idx];
      final sources = {...o.source.split(' + '), i.source}.join(' + ');
      out[idx] = o.copyWith(
        source: sources,
        delaySec: math.max(o.delaySec, i.delaySec),
        description: o.description ?? i.description,
        road: o.road ?? i.road,
      );
    }
    out.sort((a, b) => a.alongM.compareTo(b.alongM));
    return out;
  }

  static int _group(TrafficCategory c) => switch (c) {
        TrafficCategory.closed ||
        TrafficCategory.roadworks ||
        TrafficCategory.laneClosed =>
          1,
        TrafficCategory.jam || TrafficCategory.accident => 2,
        _ => 3,
      };

  static bool _same(TrafficIncident a, TrafficIncident b) {
    if (_group(a.category) != _group(b.category)) return false;
    const gap = 300.0;
    return a.alongM - gap <= b.endAlongM && b.alongM - gap <= a.endAlongM;
  }
}

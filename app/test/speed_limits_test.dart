import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/navigation.dart';
import 'package:schraeglage/services/routing_engine.dart';
import 'package:schraeglage/services/speed_limits.dart';

import 'helpers.dart';

class FixedLimits implements SpeedLimitSource {
  FixedLimits(this.limits);
  final List<SpeedLimit> limits;
  int calls = 0;
  @override
  Future<List<SpeedLimit>> forRoute(List<RoutePoint> pts) async {
    calls++;
    return limits;
  }
}

void main() {
  const home = RoutePoint(48.5, 9.0);

  group('Antwort lesen', () {
    test('Zahlen, "unlimited", mph, Unsinn', () {
      expect(ValhallaSpeedLimits.parseLimit(50, 'kilometers'), 50);
      expect(ValhallaSpeedLimits.parseLimit('unlimited', null),
          SpeedLimit.unlimited);
      expect(ValhallaSpeedLimits.parseLimit(30, 'miles'), 48);
      expect(ValhallaSpeedLimits.parseLimit(0, null), isNull);
      expect(ValhallaSpeedLimits.parseLimit('70', null), 70);
      expect(ValhallaSpeedLimits.parseLimit(null, null), isNull);
      expect(ValhallaSpeedLimits.parseLimit(255, null), SpeedLimit.unlimited);
    });

    test('Kanten werden auf das eigene Routenstueck umgerechnet', () {
      // Server-Linie 2 km lang, 3 Kanten: 50 / unbekannt / 100.
      final shape = straight(home, 90, 2000, step: 100); // 21 Punkte
      final j = {
        'units': 'kilometers',
        'shape': encodePolyline(shape),
        'edges': [
          {'speed_limit': 50, 'begin_shape_index': 0, 'end_shape_index': 5},
          {'begin_shape_index': 5, 'end_shape_index': 10},
          {'speed_limit': 100, 'begin_shape_index': 10, 'end_shape_index': 20},
        ],
      };
      // Eigenes Stueck: ab 10 km, 2,1 km lang (5 % laenger).
      final l = ValhallaSpeedLimits.parse(j, 10000, 2100);
      expect(l.length, 2);
      expect(l[0].kmh, 50);
      expect(l[0].fromM, closeTo(10000, 1));
      expect(l[0].toM, closeTo(10525, 2));
      expect(l[1].kmh, 100);
      expect(l[1].toM, closeTo(12100, 2));
    });

    test('Zusammenfassen: gleiche Nachbarn, kleine Luecken, Ueberlappung',
        () {
      final m = ValhallaSpeedLimits.merge(const [
        SpeedLimit(0, 100, 50),
        SpeedLimit(110, 300, 50), // Luecke 10 m: zu
        SpeedLimit(300, 500, 70),
        SpeedLimit(480, 900, 70), // Ueberlappung am Stueckrand
        SpeedLimit(1000, 1200, 70), // echte Luecke 100 m bleibt
      ]);
      expect(m.length, 3);
      expect((m[0].fromM, m[0].toM, m[0].kmh), (0, 300, 50));
      expect((m[1].fromM, m[1].toM, m[1].kmh), (300, 900, 70));
      expect(m[2].fromM, 1000);
    });

    test('Nachschlagen und naechster Wechsel', () {
      const l = [
        SpeedLimit(0, 1000, 100),
        SpeedLimit(1000, 1500, 70),
        SpeedLimit(2000, 3000, 70),
      ];
      expect(limitAt(l, 500)!.kmh, 100);
      expect(limitAt(l, 1000)!.kmh, 70);
      expect(limitAt(l, 1700), isNull);
      expect(limitAt(l, 3500), isNull);
      expect(nextChange(l, 800)!.kmh, 70);
      expect(nextChange(l, 1200), isNull); // 70 bleibt 70
    });

    test('Stuecke fuer den Server: Laenge und Punktzahl begrenzt', () {
      final pts = straight(home, 90, 180000, step: 50);
      final cum = cumulativeDistances(pts);
      final ch = ValhallaSpeedLimits.chunks(cum);
      expect(ch.first.$1, 0);
      expect(ch.last.$2, pts.length - 1);
      for (var i = 0; i < ch.length; i++) {
        final (a, b) = ch[i];
        expect(cum[b] - cum[a], lessThanOrEqualTo(ValhallaSpeedLimits.chunkM));
        expect(b - a, lessThan(ValhallaSpeedLimits.chunkMaxPoints));
        if (i > 0) expect(a, ch[i - 1].$2); // lueckenlos
      }
    });
  });

  test('Abfrage: ein Aufruf je Route, im Speicher gehalten', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(req.url.path, '/trace_attributes');
      final shape = decodePolyline(body['encoded_polyline'] as String);
      return http.Response(
          jsonEncode({
            'units': 'kilometers',
            'shape': encodePolyline(shape),
            'edges': [
              {
                'speed_limit': 80,
                'begin_shape_index': 0,
                'end_shape_index': shape.length - 1,
              },
            ],
          }),
          200);
    });
    final src = ValhallaSpeedLimits(base: 'https://x.test', client: client);
    final pts = straight(home, 90, 20000, step: 100);
    final a = await src.forRoute(pts);
    final b = await src.forRoute(pts);
    expect(calls, 1);
    expect(identical(a, b), isTrue);
    expect(a.single.kmh, 80);
    expect(a.single.toM, closeTo(20000, 5));
  });

  test('ohne Netz: leer, beim naechsten Mal neuer Versuch', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      throw http.ClientException('offline');
    });
    final src = ValhallaSpeedLimits(base: 'https://x.test', client: client);
    final pts = straight(home, 90, 5000, step: 100);
    expect(await src.forRoute(pts), isEmpty);
    await Future<void>.delayed(Duration.zero);
    await src.forRoute(pts);
    expect(calls, 2);
  });

  group('Navigation', () {
    EngineRoute line() {
      final pts = straight(home, 90, 5000, step: 50);
      return EngineRoute(points: pts, distanceM: 5000, durationSec: 300, steps: [
        RouteStep(text: 'Los', distanceM: 0, pointIndex: 0, type: ManeuverType.start),
        RouteStep(text: 'Ziel', distanceM: 0, pointIndex: pts.length - 1,
            type: ManeuverType.destination),
      ]);
    }

    test('Limit an der Stelle, zu schnell, eine Ansage je Abschnitt',
        () async {
      final r = line();
      final said = <String>[];
      final nav = NavigationSession(
        plan: RoutePlan(points: r.points, distanceM: r.distanceM, steps: r.steps),
        engine: FakeEngine(),
        prefs: const RoutingPrefs(),
        limits: FixedLimits(const [
          SpeedLimit(0, 2000, 100),
          SpeedLimit(2000, 5000, 70),
        ]),
        speedWarning: true,
        speak: said.add,
      );
      await Future<void>.delayed(Duration.zero);
      final cum = cumulativeDistances(r.points);
      var p = pointAlong(r.points, cum, 1000);
      nav.update(p.lat, p.lon, speedMs: 100 / 3.6);
      expect(nav.speedLimit!.kmh, 100);
      expect(nav.speeding, isFalse);
      // 102 km/h bei 100: innerhalb der Toleranz.
      nav.update(p.lat, p.lon, speedMs: 102 / 3.6);
      expect(nav.speeding, isFalse);

      p = pointAlong(r.points, cum, 2500);
      nav.update(p.lat, p.lon, speedMs: 90 / 3.6);
      expect(nav.speedLimit!.kmh, 70);
      expect(nav.speeding, isTrue);
      said.clear();
      // Erst nach 4 s zu schnell wird gewarnt - Zeit simulieren.
      nav.debugOverSince = DateTime.now().subtract(const Duration(seconds: 5));
      nav.update(p.lat, p.lon, speedMs: 90 / 3.6);
      nav.debugOverSince = DateTime.now().subtract(const Duration(seconds: 5));
      nav.update(p.lat, p.lon, speedMs: 90 / 3.6);
      expect(said.where((s) => s.contains('Tempolimit 70')).length, 1);

      // Abseits der Route: kein Limit.
      final off = destinationPoint(p, 0, 300);
      nav.update(off.lat, off.lon, speedMs: 90 / 3.6);
      expect(nav.speedLimit, isNull);
    });

    test('ohne Ansage-Option: nur Anzeige', () async {
      final r = line();
      final said = <String>[];
      final nav = NavigationSession(
        plan: RoutePlan(points: r.points, distanceM: r.distanceM, steps: r.steps),
        engine: FakeEngine(),
        prefs: const RoutingPrefs(),
        limits: FixedLimits(const [SpeedLimit(0, 5000, 50)]),
        speak: said.add,
      );
      await Future<void>.delayed(Duration.zero);
      final p = pointAlong(r.points, cumulativeDistances(r.points), 1000);
      nav.debugOverSince = DateTime.now().subtract(const Duration(seconds: 9));
      nav.update(p.lat, p.lon, speedMs: 80 / 3.6);
      expect(nav.speeding, isTrue);
      expect(said.where((s) => s.contains('Tempolimit')), isEmpty);
    });
  });
}

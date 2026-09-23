import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/navigation.dart';
import 'package:schraeglage/services/routing_engine.dart';
import 'package:schraeglage/services/traffic_eta.dart';

import 'helpers.dart';

void main() {
  const home = RoutePoint(48.0, 9.0);

  test('Stuetzpunkte: ausgeduennt, Anfang und Ende bleiben', () {
    final pts = straight(home, 90, 300000, step: 20);
    final sp = TomTomEta.supportingPoints(pts);
    expect(sp.length, lessThanOrEqualTo(TomTomEta.maxPoints + 1));
    expect(dist(sp.first, pts.first), lessThan(1));
    expect(dist(sp.last, pts.last), lessThan(160));
  });

  test('Anfrage: eigene Linie als supportingPoints, Antwort gelesen',
      () async {
    late Map<String, dynamic> body;
    late Uri url;
    final client = MockClient((req) async {
      url = req.url;
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
          jsonEncode({
            'routes': [
              {
                'summary': {
                  'lengthInMeters': 20100,
                  'travelTimeInSeconds': 1500,
                  'trafficDelayInSeconds': 420,
                },
              },
            ],
          }),
          200);
    });
    final pts = straight(home, 90, 20000, step: 50);
    final e = await TomTomEta('K', client: client).forRoute(pts);
    expect(url.queryParameters['traffic'], 'true');
    expect(url.path, contains('calculateRoute/48.000000,9.000000:'));
    expect((body['supportingPoints'] as List).length, greaterThan(100));
    expect(e!.travelSec, 1500);
    expect(e.delaySec, 420);
  });

  test('Fehler oder kein Netz: null, Navigation schaetzt selbst', () async {
    final client = MockClient((req) async => http.Response('{}', 403));
    final pts = straight(home, 90, 20000, step: 50);
    expect(await TomTomEta('K', client: client).forRoute(pts), isNull);
  });

  test('Navigation nutzt die Fahrzeit mit Verkehr und rechnet anteilig',
      () async {
    final client = MockClient((req) async => http.Response(
        jsonEncode({
          'routes': [
            {
              'summary': {
                'lengthInMeters': 30000,
                'travelTimeInSeconds': 3600,
                'trafficDelayInSeconds': 1200,
              },
            },
          ],
        }),
        200));
    final pts = straight(home, 90, 30000, step: 50);
    final nav = NavigationSession(
      plan: RoutePlan(points: pts, distanceM: 30000, durationSec: 1800, steps: [
        RouteStep(text: 'Los', distanceM: 0, pointIndex: 0, type: ManeuverType.start),
        RouteStep(text: 'Ziel', distanceM: 0, pointIndex: pts.length - 1,
            type: ManeuverType.destination),
      ]),
      engine: FakeEngine(),
      prefs: const RoutingPrefs(),
      etaSource: TomTomEta('K', client: client),
    );
    final cum = cumulativeDistances(pts);
    var p = pointAlong(pts, cum, 0);
    nav.update(p.lat, p.lon, speedMs: 10);
    // Ohne Verkehrsdaten: Schaetzung der Engine (30 min).
    expect(nav.remainingTime.inMinutes, closeTo(30, 1));
    await nav.checkTraffic(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(nav.etaWithTraffic, isTrue);
    expect(nav.remainingTime.inMinutes, closeTo(60, 1));
    // Halbe Strecke gefahren: halbe Restzeit.
    p = pointAlong(pts, cum, 15000);
    nav.update(p.lat, p.lon, speedMs: 10);
    expect(nav.remainingTime.inMinutes, closeTo(30, 1));
  });
}

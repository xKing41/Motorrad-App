import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/geo.dart';
import 'package:schraeglage/services/navigation.dart';
import 'package:schraeglage/services/offline_router.dart';
import 'package:schraeglage/services/road_check.dart';
import 'package:schraeglage/services/route_planner.dart';
import 'package:schraeglage/services/routing_engine.dart';
import 'package:schraeglage/services/user_blocks.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';

/// Meldet eine gesperrte Stelle ueberall dort, wo die Route naeher als
/// 30 m an [spot] vorbeifuehrt - wie eine echte Pruefung, die an der
/// Strasse haengt und nicht an Kilometerangaben.
class SpotCheck extends RoadCheck {
  SpotCheck(this.spot, {this.offline = false});
  final RoutePoint spot;
  bool offline;
  int calls = 0;

  @override
  String get name => 'Motorradverbote';

  @override
  Future<List<RoadIssue>> check(List<RoutePoint> pts,
      {bool unpaved = true}) async {
    calls++;
    if (offline) throw StateError('kein Netz');
    final cum = cumulativeDistances(pts);
    final hit = projectOnPolyline(spot, pts, cum);
    if (hit == null || hit.distanceM > 30) return const [];
    return [RoadIssue(math.max(0, hit.alongM - 400),
        math.min(cum.last, hit.alongM + 400), 'Motorradverbot (Sa,Su,PH)')];
  }
}

void main() {
  const home = RoutePoint(51.30, 7.40);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RoutingEngine.globalAvoid = () => const [];
  });

  group('Eigene Sperrliste', () {
    test('bleibt gespeichert und gilt fuer jede Berechnung', () async {
      final u = UserBlocks();
      await u.load();
      final spot = destinationPoint(home, 90, 3000);
      await u.add(spot, 'Motorradverbot');
      // "App neu gestartet"
      final u2 = UserBlocks();
      await u2.load();
      expect(u2.blocks.single.label, 'Motorradverbot');
      expect(u2.near(destinationPoint(spot, 0, 30))?.label, 'Motorradverbot');
      expect(u2.near(destinationPoint(spot, 0, 300)), isNull);

      // Jede Anfrage in der Gegend meidet die Stelle.
      final wps = [
        const Waypoint(home, WaypointKind.endpoint),
        Waypoint(destinationPoint(home, 90, 8000), WaypointKind.endpoint),
      ];
      final p = RoutingEngine.withGlobalAvoid(wps, const RoutingPrefs());
      expect(p.avoid.single.lat, closeTo(spot.lat, 1e-9));
      expect(p.avoid.single.lon, closeTo(spot.lon, 1e-9));
      final req = ValhallaEngine().buildRequest(wps, p);
      expect((req['exclude_locations'] as List).single['lat'],
          closeTo(spot.lat, 1e-6));
      // Weit weg (anderes Bundesland): nicht mitschicken.
      final far = [
        const Waypoint(RoutePoint(48.1, 11.5), WaypointKind.endpoint),
        const Waypoint(RoutePoint(48.2, 11.6), WaypointKind.endpoint),
      ];
      expect(RoutingEngine.withGlobalAvoid(far, const RoutingPrefs()).avoid,
          isEmpty);
      // Direkt am Ziel: sonst gaebe es gar keinen Weg.
      final atGoal = [
        const Waypoint(home, WaypointKind.endpoint),
        Waypoint(destinationPoint(spot, 0, 50), WaypointKind.endpoint),
      ];
      expect(RoutingEngine.withGlobalAvoid(atGoal, const RoutingPrefs()).avoid,
          isEmpty);

      await u2.remove(u2.blocks.single.id);
      final u3 = UserBlocks();
      await u3.load();
      expect(u3.blocks, isEmpty);
    });

    test('Pruefung findet die Stelle auf der Route; Sicherung ohne Doppel',
        () async {
      final u = UserBlocks();
      await u.load();
      final route = straight(home, 90, 10000);
      final cum = cumulativeDistances(route);
      final b = await u.add(pointAlong(route, cum, 6000), 'Baustelle');
      final l = await UserBlockCheck(u).check(route);
      expect(l.single.kind, 'von dir gesperrt (Baustelle)');
      expect((l.single.fromM + l.single.toM) / 2, closeTo(6000, 20));
      await u.addExisting(UserBlock.fromJson(b.toJson())!);
      expect(u.blocks, hasLength(1));
    });
  });

  group('Planen', () {
    test('Pruefung ausgefallen: die Tour sagt es', () async {
      final plan = await TourPlanner(FakeEngine(),
              random: math.Random(4),
              maxVariants: 1,
              roadCheck: CombinedRoadCheck(
                  [SpotCheck(home, offline: true), UserBlockCheck(UserBlocks())]))
          .plan(RouteRequest(
              startLat: home.lat, startLon: home.lon, distanceKm: 60));
      final note = plan.notes.singleWhere((n) => n.startsWith('Nicht geprüft'));
      expect(note, contains('Motorradverbote'));
      expect(note, isNot(contains('eigene Sperren')));
    });
  });

  group('Navigation', () {
    EngineRoute line(double km) {
      final pts = straight(home, 90, km * 1000);
      return EngineRoute(points: pts, distanceM: km * 1000, durationSec: 600);
    }

    RoutePlan planOf(EngineRoute r) =>
        RoutePlan(points: r.points, distanceM: r.distanceM, steps: r.steps);

    test('vor der Fahrt: Stelle gefunden, umfahren, sonst Warnung', () async {
      final r = line(30);
      final cum = cumulativeDistances(r.points);
      final spot = pointAlong(r.points, cum, 15000);
      final engine = FakeEngine();
      final said = <String>[];
      final nav = NavigationSession(
        plan: planOf(r),
        engine: engine,
        prefs: const RoutingPrefs(),
        roadCheck: SpotCheck(spot),
        speak: said.add,
      );
      nav.update(home.lat, home.lon, heading: 90, speedMs: 10);
      final found = await nav.checkSection(nav.alongM, nav.totalM);
      expect(found!.single.fromM, closeTo(14600, 30));

      // Umfahren: nur ein Stueck um die Stelle, mit Meide-Punkten.
      final n = await nav.avoidIssues(found);
      expect(n, 1);
      final req = engine.requests.first;
      expect(dist(req.first.point, pointAlong(r.points, cum, 10600)),
          lessThan(40));
      expect(engine.prefsSeen.first.avoid, isNotEmpty);
      // Die Test-Engine faehrt stur geradeaus - die Stelle bleibt. Nach
      // zwei weiteren Versuchen gibt es eine Warnung statt Endlosschleife.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(engine.calls, lessThanOrEqualTo(3));
      expect(said.where((s) => s.contains('für Motorräder gesperrt')),
          isNotEmpty);
    });

    test('"Trotzdem fahren": kurz vorher gewarnt, einmal', () async {
      final r = line(10);
      final cum = cumulativeDistances(r.points);
      final said = <String>[];
      final nav = NavigationSession(
        plan: planOf(r),
        engine: FakeEngine(),
        prefs: const RoutingPrefs(),
        speak: said.add,
      );
      nav.hazards = [const RoadIssue(6000, 7000, 'Motorradverbot')];
      for (var m = 0.0; m < 6500; m += 100) {
        final p = pointAlong(r.points, cum, m);
        nav.update(p.lat, p.lon, heading: 90, speedMs: 15);
      }
      final warns = said.where((s) => s.contains('gesperrt')).toList();
      expect(warns, hasLength(1));
      expect(warns.single, contains('in 1,5 Kilometern'));
    });

    test('ohne Netz: kein Ergebnis statt "alles frei"', () async {
      final r = line(10);
      final nav = NavigationSession(
        plan: planOf(r),
        engine: FakeEngine(),
        prefs: const RoutingPrefs(),
        roadCheck: SpotCheck(home, offline: true),
      );
      expect(await nav.checkSection(0, nav.totalM), isNull);
    });
  });

  group('Ohne Netz neu rechnen', () {
    test('gesperrter Weg und eigene Sperre werden gemieden, Kreuzung nicht',
        () {
      final a = home, b = destinationPoint(home, 90, 500);
      final banned = [a, b];
      final blocker = EdgeBlocker(const [], [banned]);
      expect(blocker.blocks(destinationPoint(a, 90, 100),
          destinationPoint(a, 90, 300)), isTrue);
      // Querstrasse, die den gesperrten Weg kreuzt.
      final mid = destinationPoint(a, 90, 250);
      expect(blocker.blocks(destinationPoint(mid, 0, 200),
          destinationPoint(mid, 180, 20)), isFalse);
      final own = EdgeBlocker([mid], const []);
      expect(own.blocks(a, b), isTrue);
      expect(own.blocks(destinationPoint(mid, 0, 100),
          destinationPoint(mid, 0, 400)), isFalse);
    });
  });
}

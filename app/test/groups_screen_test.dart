import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/screens/groups_screen.dart';
import 'package:schraeglage/services/group_ride.dart';
import 'package:schraeglage/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'group_ride_test.dart' show Bus, MemTransport;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Zeitangaben lesbar', () {
    final now = DateTime(2026, 10, 1, 12); // Donnerstag
    expect(fmtWhen(DateTime(2026, 10, 1, 18, 30), now), 'Heute 18:30');
    expect(fmtWhen(DateTime(2026, 10, 2, 9, 5), now), 'Morgen 09:05');
    expect(fmtWhen(DateTime(2026, 10, 3, 10), now), 'Sa 3.10. 10:00');
  });

  testWidgets('Gruppenliste, Chat, Ausfahrten und Mitglieder bauen sich auf',
      (tester) async {
    final bus = Bus();
    final hub = GroupHub(transport: () => MemTransport(bus));
    late GroupSession g;
    await tester.runAsync(() async {
      await hub.restore('Faruk');
      g = await hub.create('Sauerland-Biker');
      await g.sendChat('Sonntag jemand?');
      await g.saveRide(RideEvent(
        id: 'r1',
        title: 'Eisdiele Möhnesee',
        when: DateTime.now().add(const Duration(days: 1)),
        byName: 'Faruk',
        byId: hub.myId!,
        meetName: 'Tanke Wetter',
        meet: const RoutePoint(51.38, 7.28),
      ));
    });
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: GroupsScreen(
          hub: hub, onLoadTour: (_) {}, onGoTo: (_) {}, lat: 51.4, lon: 7.3),
    ));
    expect(find.text('Sauerland-Biker'), findsOneWidget);
    expect(find.textContaining('Eisdiele'), findsOneWidget);

    await tester.tap(find.text('Sauerland-Biker'));
    await tester.pumpAndSettle();
    expect(find.text('Sonntag jemand?'), findsOneWidget);

    await tester.tap(find.textContaining('AUSFAHRTEN'));
    await tester.pumpAndSettle();
    expect(find.text('Eisdiele Möhnesee'), findsOneWidget);
    expect(find.textContaining('Tanke Wetter'), findsOneWidget);

    await tester.tap(find.text('MITGLIEDER'));
    await tester.pumpAndSettle();
    expect(find.text(g.code), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

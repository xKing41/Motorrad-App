import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/services/companion.dart';
import 'package:schraeglage/services/emergency.dart';

void main() {
  late List<String> sent;
  late Companion c;
  final em = Emergency.instance;

  setUp(() {
    sent = [];
    em
      ..contactPhone = '+49 170 1234567'
      ..riderName = 'Faruk'
      ..companion = true
      ..companionEveryMin = 30;
    c = Companion(em, send: (t) async {
      sent.add(t);
      return true;
    });
  });

  test('Start, alle 30 Minuten Position, Ende', () async {
    final t0 = DateTime(2026, 6, 1, 10, 5);
    await c.rideStarted(t0, lat: 48.1, lon: 9.2);
    expect(sent.single,
        startsWith('Faruk ist um 10:05 losgefahren. Start: https://www.openstreetmap.org/?mlat=48.10000'));
    expect(sent.single, contains('etwa alle 30 Minuten'));

    await c.tick(t0.add(const Duration(minutes: 29)), 20, lat: 48.2, lon: 9.3);
    expect(sent.length, 1);
    await c.tick(t0.add(const Duration(minutes: 30)), 25.4, lat: 48.2, lon: 9.3);
    expect(sent.length, 2);
    expect(sent[1], startsWith('Faruk unterwegs, 10:35 Uhr, bisher 25 km.'));
    await c.tick(t0.add(const Duration(minutes: 45)), 40);
    expect(sent.length, 2);
    await c.tick(t0.add(const Duration(minutes: 61)), 50);
    expect(sent[2], contains('Gerade kein GPS.'));

    await c.rideEnded(t0.add(const Duration(hours: 2)), 142.6);
    expect(sent.last, 'Faruk hat die Fahrt um 12:05 beendet - 143 km. (Schräglage-App)');
    // Danach nichts mehr.
    await c.tick(t0.add(const Duration(hours: 5)), 1);
    expect(sent.length, 4);
  });

  test('ausgeschaltet oder ohne Nummer: keine SMS', () async {
    em.companion = false;
    await c.rideStarted(DateTime(2026), lat: 1, lon: 1);
    await c.rideEnded(DateTime(2026), 10);
    em
      ..companion = true
      ..contactPhone = '';
    await c.rideStarted(DateTime(2026));
    expect(sent, isEmpty);
  });

  test('nur Start und Ende; ohne Namen in der Ich-Form', () async {
    em
      ..companionEveryMin = 0
      ..riderName = '';
    final t0 = DateTime(2026, 6, 1, 9);
    await c.rideStarted(t0);
    await c.tick(t0.add(const Duration(hours: 3)), 100);
    await c.rideEnded(t0.add(const Duration(hours: 3)), 100);
    expect(sent.length, 2);
    expect(sent[0], 'Ich bin um 09:00 losgefahren. (Schräglage-App)');
    expect(sent[1], startsWith('Ich habe die Fahrt um 12:00 beendet'));
  });
}

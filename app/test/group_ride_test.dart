import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:schraeglage/models/route_plan.dart';
import 'package:schraeglage/services/group_ride.dart';

import 'helpers.dart';

/// Nachrichtendienst im Speicher: alle Teilnehmer an einem "Server",
/// mit gespeicherten (retained) Nachrichten wie bei MQTT.
class Bus {
  final retained = <String, Uint8List>{};
  final clients = <MemTransport>[];
  final seen = <String>[]; // alle Kanaele, die je benutzt wurden
  final payloads = <Uint8List>[];

  void publish(String topic, Uint8List data, bool retain) {
    seen.add(topic);
    payloads.add(data);
    if (retain) {
      if (data.isEmpty) {
        retained.remove(topic);
      } else {
        retained[topic] = data;
      }
    }
    for (final c in clients) {
      c.deliver(topic, data);
    }
  }
}

class MemTransport implements GroupTransport {
  MemTransport(this.bus);
  final Bus bus;
  final _out = StreamController<(String, Uint8List)>.broadcast();
  final _filters = <String>[];
  bool _on = false;

  bool _match(String t) => _filters
      .any((f) => f.endsWith('#') ? t.startsWith(f.substring(0, f.length - 1)) : t == f);

  void deliver(String topic, Uint8List data) {
    if (_on && _match(topic)) _out.add((topic, data));
  }

  @override
  Stream<(String, Uint8List)> get messages => _out.stream;
  @override
  bool get connected => _on;
  @override
  Future<void> connect(String clientId) async {
    _on = true;
    bus.clients.add(this);
    for (final e in bus.retained.entries.toList()) {
      deliver(e.key, e.value);
    }
  }

  @override
  void subscribe(String filter) => _filters.add(filter);
  @override
  void publish(String topic, Uint8List data, {bool retain = false}) =>
      bus.publish(topic, data, retain);
  @override
  Future<void> disconnect() async {
    _on = false;
    bus.clients.remove(this);
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  test('Codes: lesbar, ohne verwechselbare Zeichen, Eingabe tolerant', () {
    final c = GroupSession.newCode(math.Random(1));
    expect(c, matches(RegExp(r'^[A-Z2-9]{5}-[A-Z2-9]{5}$')));
    expect(c.contains(RegExp('[01OIL]')), isFalse);
    expect(GroupSession.normalize(c.toLowerCase().replaceAll('-', ' ')), c);
    expect(GroupSession.normalize('ABC'), isNull);
    expect(GroupSession.normalize('ABCDE-FGHJ0'), isNull); // 0 gibt es nicht
  });

  test('zwei Fahrer sehen sich, Tour und Hilferuf kommen an', () async {
    final bus = Bus();
    const code = 'ABCDE-FGHJK';
    final a = GroupSession(
        transport: MemTransport(bus), code: code, myId: 'a1', myName: 'Faruk');
    final b = GroupSession(
        transport: MemTransport(bus), code: code, myId: 'b2', myName: 'Tim');
    await a.start();
    await a.sendPosition(51.4, 7.3, 20);
    final route = straight(const RoutePoint(51.4, 7.3), 90, 5000);
    await a.shareTour(RoutePlan(points: route, distanceM: 5000, title: 'Sauerland'));
    // B kommt spaeter dazu - bekommt Position und Tour trotzdem (retained).
    await b.start();
    await settle();
    expect(b.members['a1']!.name, 'Faruk');
    expect(b.members['a1']!.point.lat, closeTo(51.4, 1e-4));
    expect(b.groupTour!.title, 'Sauerland');
    expect(b.tourFrom, 'Faruk');

    await b.sendPosition(51.41, 7.31, 15);
    await settle();
    expect(a.members['b2']!.name, 'Tim');
    expect(a.members.containsKey('a1'), isFalse); // sich selbst nicht

    await b.sendSos(51.41, 7.31);
    await settle();
    expect(a.lastSos!.name, 'Tim');

    // B verlaesst die Gruppe: verschwindet bei A.
    await b.leave();
    await settle();
    expect(a.members.containsKey('b2'), isFalse);
  });

  test('ohne Code: Kanal verraet nichts, Inhalte nicht lesbar', () async {
    final bus = Bus();
    final a = GroupSession(
        transport: MemTransport(bus), code: 'ABCDE-FGHJK', myId: 'a1', myName: 'Faruk');
    final spy = GroupSession(
        transport: MemTransport(bus), code: 'ZZZZZ-ZZZZZ', myId: 's', myName: 'X');
    await a.start();
    await spy.start();
    await a.sendPosition(51.4, 7.3, 20);
    await settle();
    expect(spy.members, isEmpty);
    expect(bus.seen.any((t) => t.contains('ABCDE')), isFalse);
    // Der Name steht nirgends im Klartext.
    final all = bus.payloads.expand((p) => p).toList();
    expect(String.fromCharCodes(all).contains('Faruk'), isFalse);
  });

  test('Position hoechstens alle 10 Sekunden', () async {
    final bus = Bus();
    final a = GroupSession(
        transport: MemTransport(bus), code: 'ABCDE-FGHJK', myId: 'a1', myName: 'F');
    await a.start();
    final t0 = DateTime(2026, 6, 1, 10);
    await a.sendPosition(51, 7, 10, now: t0);
    await a.sendPosition(51, 7, 10, now: t0.add(const Duration(seconds: 5)));
    await a.sendPosition(51, 7, 10, now: t0.add(const Duration(seconds: 11)));
    expect(bus.seen.where((t) => t.contains('/pos/')).length, 2);
  });

  test('Chat: wer spaeter kommt, sieht den Verlauf; Ungelesen zaehlt', () async {
    final bus = Bus();
    const code = 'ABCDE-FGHJK';
    final a = GroupSession(
        transport: MemTransport(bus), code: code, myId: 'a1', myName: 'Faruk');
    final b = GroupSession(
        transport: MemTransport(bus), code: code, myId: 'b2', myName: 'Tim');
    await a.start();
    await a.sendChat('Wer faehrt Sonntag?');
    await a.sendChat('  ');
    await b.start();
    await settle();
    expect(b.chat.map((m) => m.text), ['Wer faehrt Sonntag?']);
    expect(b.unread, 0); // Verlauf ist nicht "neu"
    await a.sendChat('Start 10 Uhr');
    await settle();
    expect(b.chat.last.text, 'Start 10 Uhr');
    expect(b.chat.last.from, 'Faruk');
    expect(b.unread, 1);
    expect(a.unread, 0); // eigene zaehlen nicht
    b.markRead();
    expect(b.unread, 0);
    await b.sendChat('Bin dabei');
    await settle();
    expect(a.chat.map((m) => m.text),
        ['Wer faehrt Sonntag?', 'Start 10 Uhr', 'Bin dabei']);
  });

  test('Ausfahrt mit Treffpunkt und Tour, Zu- und Absagen', () async {
    final bus = Bus();
    const code = 'ABCDE-FGHJK';
    final a = GroupSession(
        transport: MemTransport(bus), code: code, myId: 'a1', myName: 'Faruk');
    final b = GroupSession(
        transport: MemTransport(bus), code: code, myId: 'b2', myName: 'Tim');
    await a.start();
    final route = straight(const RoutePoint(51.4, 7.3), 90, 80000);
    final r = RideEvent(
      id: GroupSession.newRideId(),
      title: 'Sauerland-Runde',
      when: DateTime.now().add(const Duration(days: 2)),
      byName: 'Faruk',
      byId: 'a1',
      meet: const RoutePoint(51.38, 7.28),
      meetName: 'Tanke Wetter',
      tour: RoutePlan(points: route, distanceM: 80000),
    );
    await a.saveRide(r);
    await a.rsvp(r.id, true);
    await b.start();
    await settle();
    final got = b.upcoming.single;
    expect(got.title, 'Sauerland-Runde');
    expect(got.meetName, 'Tanke Wetter');
    expect(got.meet!.lat, closeTo(51.38, 1e-6));
    expect(got.km, closeTo(80, 0.1));
    expect(b.tourFor(got)!.points.length, route.length);
    expect(b.going(r.id), ['Faruk']);
    await b.rsvp(r.id, true);
    await settle();
    expect(a.going(r.id)..sort(), ['Faruk', 'Tim']);
    await b.rsvp(r.id, false);
    await settle();
    expect(a.going(r.id), ['Faruk']);
    expect(a.myRsvp(r.id), isTrue);
    expect(b.myRsvp(r.id), isFalse);
    // Die Liste bleibt klein - die Tour kommt als eigene Nachricht.
    expect(bus.retained.keys.where((k) => k.endsWith('/rides')), hasLength(1));
    final ridesSize = bus.retained.entries
        .firstWhere((e) => e.key.endsWith('/rides'))
        .value
        .length;
    expect(ridesSize, lessThan(2000));

    await a.deleteRide(r.id);
    await settle();
    expect(b.upcoming, isEmpty);
    expect(b.rideTours, isEmpty);
    expect(bus.retained.keys.any((k) => k.contains('/ridetour/')), isFalse);
  });

  test('ohne Netz: Chat wartet und geht spaeter raus, Position nicht', () async {
    final bus = Bus();
    const code = 'ABCDE-FGHJK';
    final ta = MemTransport(bus);
    final a = GroupSession(
        transport: ta, code: code, myId: 'a1', myName: 'Faruk',
        ownsTransport: false);
    final b = GroupSession(
        transport: MemTransport(bus), code: code, myId: 'b2', myName: 'Tim');
    await a.start(); // geteilte Verbindung: noch nicht verbunden
    await b.start();
    await a.sendChat('Funkloch-Gruss');
    await a.sendPosition(51, 7, 10);
    expect(a.pending, 2); // Chat + Verlauf
    await settle();
    expect(b.chat, isEmpty);
    await ta.connect('x');
    await a.flush();
    await settle();
    expect(a.pending, 0);
    expect(b.chat.single.text, 'Funkloch-Gruss');
    expect(b.members, isEmpty);
  });

  group('GroupHub', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('Gruppen bleiben nach dem Schliessen, mehrere gleichzeitig', () async {
      final bus = Bus();
      final hub = GroupHub(transport: () => MemTransport(bus));
      await hub.restore('Faruk');
      final g1 = await hub.create('Sauerland-Biker');
      final g2 = await hub.join('ZZZZZ-ZZZZZ');
      await hub.setShareLive(g2, false);
      expect(hub.sessions, hasLength(2));
      expect(hub.online, isTrue);
      final id = hub.myId;

      // App neu gestartet: alles wieder da, gleiche Kennung.
      final hub2 = GroupHub(transport: () => MemTransport(bus));
      await hub2.restore('Faruk');
      await settle();
      expect(hub2.myId, id);
      expect(hub2.sessions.map((s) => s.code), [g1.code, 'ZZZZZ-ZZZZZ']);
      expect(hub2.sessions.first.name, 'Sauerland-Biker');
      expect(hub2.sessions.last.shareLive, isFalse);

      // Austreten ist dauerhaft.
      await hub2.leave(hub2.sessions.last);
      final hub3 = GroupHub(transport: () => MemTransport(bus));
      await hub3.restore('Faruk');
      expect(hub3.sessions.map((s) => s.code), [g1.code]);
    });

    test('Position und Funk nur an Gruppen mit Live-Teilen', () async {
      final bus = Bus();
      final hub = GroupHub(transport: () => MemTransport(bus));
      await hub.restore('Faruk');
      final ride = await hub.create('Fahrgruppe');
      final club = await hub.create('Stammtisch');
      await hub.setShareLive(club, false);
      final watchRide = GroupSession(
          transport: MemTransport(bus), code: ride.code, myId: 'w1', myName: 'W');
      final watchClub = GroupSession(
          transport: MemTransport(bus), code: club.code, myId: 'w2', myName: 'W');
      await watchRide.start();
      await watchClub.start();
      await hub.sendPosition(51.4, 7.3, 20);
      final ok = await hub.sendVoice(Uint8List.fromList([1, 2, 3]),
          const Duration(seconds: 1));
      await settle();
      expect(ok, isTrue);
      expect(watchRide.members.keys, [hub.myId]);
      expect(watchClub.members, isEmpty);
      expect(watchRide.voices, hasLength(1));
      expect(watchClub.voices, isEmpty);
      // Mitfahrer aus allen Gruppen, jeder nur einmal.
      await watchRide.sendPosition(51.5, 7.4, 10);
      await watchClub.sendPosition(51.5, 7.4, 10);
      await settle();
      expect(hub.members.map((m) => m.id).toSet(), {'w1', 'w2'});
      // SOS geht an alle Gruppen.
      await hub.sendSos(51.4, 7.3);
      await settle();
      expect(watchClub.lastSos!.name, 'Faruk');
      expect(watchRide.lastSos!.name, 'Faruk');
    });

    test('Hintergrund: Verbindung ruht, danach kommt Verpasstes nach',
        () async {
      final bus = Bus();
      final hub = GroupHub(transport: () => MemTransport(bus));
      await hub.restore('Faruk');
      final g = await hub.create('Clique');
      final other = GroupSession(
          transport: MemTransport(bus), code: g.code, myId: 'o', myName: 'Tim');
      await other.start();
      await hub.pause();
      expect(hub.online, isFalse);
      await other.sendChat('Morgen 9 Uhr?');
      await settle();
      expect(g.chat, isEmpty);
      await hub.resume();
      await settle();
      expect(hub.online, isTrue);
      // Verlauf (retained) bringt die verpasste Nachricht.
      expect(g.chat.single.text, 'Morgen 9 Uhr?');
    });
  });
}

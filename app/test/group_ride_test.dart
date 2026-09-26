import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
}

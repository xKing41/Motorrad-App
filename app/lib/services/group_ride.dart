import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_buffers.dart';

import '../models/route_plan.dart';
import 'tour_store.dart';

// ---------------------------------------------------------------------------
//  GRUPPENFAHRT
//
//  Wer faehrt mit, wo sind die anderen, ist jemand zurueckgefallen oder
//  gestuerzt? Die Handys tauschen dazu ihre Position aus.
//
//  Ohne eigenen Server laeuft das ueber einen oeffentlichen
//  Nachrichtendienst (MQTT - dasselbe Verfahren, das viele Smart-Home-
//  Geraete nutzen). Damit dort niemand mitlesen kann:
//   * Der Gruppencode (10 Zeichen) wird NIE uebertragen. Aus ihm werden
//     der Kanalname (Pruefsumme) und der Schluessel abgeleitet.
//   * Jede Nachricht ist mit AES-256-GCM verschluesselt - der Dienst
//     sieht nur Zeichensalat. Wer den Code nicht hat, kann weder lesen
//     noch gefaelschte Positionen einschleusen.
//
//  Fuer die Verteilung an viele Nutzer gehoert hierher ein eigener
//  Server; oeffentliche Dienste garantieren keine Verfuegbarkeit.
//  Deshalb vorerst nur in der Test-App.
// ---------------------------------------------------------------------------

/// Transportweg fuer Gruppennachrichten (austauschbar fuer Tests).
abstract class GroupTransport {
  Future<void> connect(String clientId);
  void subscribe(String filter);
  void publish(String topic, Uint8List data, {bool retain = false});
  Stream<(String, Uint8List)> get messages;
  bool get connected;
  Future<void> disconnect();
}

/// Oeffentliche MQTT-Dienste (TLS), der erste erreichbare wird genommen.
class MqttTransport implements GroupTransport {
  MqttTransport({this.brokers = defaultBrokers});

  static const defaultBrokers = [
    ('broker.emqx.io', 8883),
    ('broker.hivemq.com', 8883),
  ];

  final List<(String, int)> brokers;
  MqttServerClient? _client;
  final _out = StreamController<(String, Uint8List)>.broadcast();
  final List<String> _subs = [];
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _listen;

  @override
  Stream<(String, Uint8List)> get messages => _out.stream;

  @override
  bool get connected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  @override
  Future<void> connect(String clientId) async {
    Object? last;
    for (final (host, port) in brokers) {
      final c = MqttServerClient.withPort(host, clientId, port)
        ..secure = true
        ..keepAlivePeriod = 60
        ..autoReconnect = true
        ..resubscribeOnAutoReconnect = true
        ..logging(on: false);
      try {
        await c.connect().timeout(const Duration(seconds: 12));
        if (c.connectionStatus?.state != MqttConnectionState.connected) {
          c.disconnect();
          continue;
        }
        _client = c;
        _listen = c.updates?.listen((batch) {
          for (final m in batch) {
            final p = m.payload;
            if (p is MqttPublishMessage) {
              _out.add((m.topic, Uint8List.fromList(p.payload.message)));
            }
          }
        });
        for (final s in _subs) {
          c.subscribe(s, MqttQos.atLeastOnce);
        }
        return;
      } catch (e) {
        last = e;
        c.disconnect();
      }
    }
    throw SocketException('Kein Gruppendienst erreichbar ($last)');
  }

  @override
  void subscribe(String filter) {
    _subs.add(filter);
    _client?.subscribe(filter, MqttQos.atLeastOnce);
  }

  @override
  void publish(String topic, Uint8List data, {bool retain = false}) {
    final c = _client;
    if (c == null || !connected) return;
    final buf = Uint8Buffer()..addAll(data);
    c.publishMessage(topic, MqttQos.atLeastOnce, buf, retain: retain);
  }

  @override
  Future<void> disconnect() async {
    await _listen?.cancel();
    _client?.disconnect();
    _client = null;
  }
}

/// Schluessel und Kanal aus dem Gruppencode.
class GroupCrypto {
  GroupCrypto._(this._key, this.channel);

  final SecretKey _key;

  /// Kanalname (Pruefsumme des Codes, verraet den Code nicht).
  final String channel;

  static final _aes = AesGcm.with256bits();

  static Future<GroupCrypto> fromCode(String code) async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(utf8.encode('schraeglage-gruppe:$code')),
      nonce: utf8.encode('schraeglage-v1'),
    );
    final ch = hash.sha256
        .convert(utf8.encode('kanal:$code'))
        .toString()
        .substring(0, 24);
    return GroupCrypto._(key, ch);
  }

  Future<Uint8List> seal(Map<String, dynamic> json) async {
    final box = await _aes.encrypt(utf8.encode(jsonEncode(json)),
        secretKey: _key);
    return Uint8List.fromList(box.concatenation());
  }

  /// null = nicht lesbar (falscher Code, manipuliert, kein JSON).
  Future<Map<String, dynamic>?> open(Uint8List data) async {
    try {
      final box = SecretBox.fromConcatenation(data,
          nonceLength: 12, macLength: 16, copy: false);
      final clear = await _aes.decrypt(box, secretKey: _key);
      final j = jsonDecode(utf8.decode(clear));
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }
}

class GroupMember {
  GroupMember({
    required this.id,
    required this.name,
    required this.point,
    required this.speedMs,
    required this.seen,
  });

  final String id;
  final String name;
  final RoutePoint point;
  final double speedMs;
  final DateTime seen;

  /// Laenger nichts gehoert (Funkloch, Pause, App zu)?
  bool staleAt(DateTime now) => now.difference(seen) > const Duration(minutes: 2);
}

/// Hilferuf aus der Gruppe (Sturzerkennung bei jemandem).
class GroupSos {
  GroupSos(this.name, this.point, this.at);
  final String name;
  final RoutePoint? point;
  final DateTime at;
}

class GroupSession extends ChangeNotifier {
  GroupSession({
    required this.transport,
    required this.code,
    required this.myId,
    required this.myName,
    this.minInterval = const Duration(seconds: 10),
  });

  final GroupTransport transport;
  final String code;
  final String myId;
  final String myName;
  final Duration minInterval;

  GroupCrypto? _crypto;
  StreamSubscription<(String, Uint8List)>? _sub;
  DateTime? _lastSent;

  final Map<String, GroupMember> members = {};
  RoutePlan? groupTour;
  String? tourFrom;
  GroupSos? lastSos;
  String? error;
  bool started = false;

  String get _base => 'schraeglage/v1/${_crypto!.channel}';

  // -------------------------------------------------------------------
  //  Codes
  // -------------------------------------------------------------------

  /// Ohne verwechselbare Zeichen (0/O, 1/I/L).
  static const _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  static String newCode([math.Random? rnd]) {
    final r = rnd ?? math.Random.secure();
    final c = List.generate(10, (_) => _alphabet[r.nextInt(_alphabet.length)])
        .join();
    return '${c.substring(0, 5)}-${c.substring(5)}';
  }

  /// Eingabe pruefen und vereinheitlichen ("abcde fghjk" -> "ABCDE-FGHJK").
  static String? normalize(String input) {
    final c = input.toUpperCase().replaceAll(RegExp(r'[\s\-_]'), '');
    if (c.length != 10) return null;
    if (c.split('').any((ch) => !_alphabet.contains(ch))) return null;
    return '${c.substring(0, 5)}-${c.substring(5)}';
  }

  static String newMemberId([math.Random? rnd]) {
    final r = rnd ?? math.Random.secure();
    return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  // -------------------------------------------------------------------

  Future<void> start() async {
    _crypto = await GroupCrypto.fromCode(code);
    _sub = transport.messages.listen(_onMessage);
    transport.subscribe('$_base/#');
    await transport.connect('sl-$myId');
    started = true;
    notifyListeners();
  }

  Future<void> _publish(String sub, Map<String, dynamic> json,
      {bool retain = false}) async {
    final c = _crypto;
    if (c == null) return;
    transport.publish('$_base/$sub', await c.seal(json), retain: retain);
  }

  /// Eigene Position (hoechstens alle [minInterval]).
  Future<void> sendPosition(double lat, double lon, double speedMs,
      {DateTime? now}) async {
    final t = now ?? DateTime.now();
    final last = _lastSent;
    if (last != null && t.difference(last) < minInterval) return;
    _lastSent = t;
    await _publish('pos/$myId', {
      'id': myId,
      'name': myName,
      'lat': double.parse(lat.toStringAsFixed(5)),
      'lon': double.parse(lon.toStringAsFixed(5)),
      'v': double.parse(speedMs.toStringAsFixed(1)),
      'ts': t.millisecondsSinceEpoch,
    }, retain: true);
  }

  /// Tour an alle schicken - wer spaeter dazukommt, bekommt sie auch.
  Future<void> shareTour(RoutePlan plan) => _publish(
      'tour', {'from': myName, 'id': myId, 'plan': planToJson(plan)},
      retain: true);

  /// Hilferuf (Sturzerkennung).
  Future<void> sendSos(double? lat, double? lon) => _publish('sos', {
        'id': myId,
        'name': myName,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
      });

  Future<void> _onMessage((String, Uint8List) m) async {
    final (topic, data) = m;
    if (!topic.startsWith('$_base/')) return;
    final sub = topic.substring(_base.length + 1);
    if (data.isEmpty) {
      // Gruppe verlassen (leere Nachricht loescht die Position).
      if (sub.startsWith('pos/')) {
        members.remove(sub.substring(4));
        notifyListeners();
      }
      return;
    }
    final j = await _crypto?.open(data);
    if (j == null) return;
    final id = j['id'] as String?;
    final now = DateTime.now();
    if (sub.startsWith('pos/')) {
      if (id == null || id == myId) return;
      final lat = (j['lat'] as num?)?.toDouble();
      final lon = (j['lon'] as num?)?.toDouble();
      if (lat == null || lon == null) return;
      final ts = DateTime.fromMillisecondsSinceEpoch(
          (j['ts'] as num?)?.toInt() ?? now.millisecondsSinceEpoch);
      // Alte, gespeicherte Positionen (Mitglied laengst weg) ignorieren.
      if (now.difference(ts) > const Duration(hours: 6)) return;
      members[id] = GroupMember(
        id: id,
        name: (j['name'] as String?)?.trim().isNotEmpty == true
            ? (j['name'] as String).trim()
            : 'Mitfahrer',
        point: RoutePoint(lat, lon),
        speedMs: (j['v'] as num?)?.toDouble() ?? 0,
        seen: ts.isAfter(now) ? now : ts,
      );
    } else if (sub == 'tour') {
      if (id == myId) return;
      final p = planFromJson(j['plan']);
      if (p == null) return;
      groupTour = p;
      tourFrom = j['from'] as String?;
    } else if (sub == 'sos') {
      if (id == myId) return;
      final lat = (j['lat'] as num?)?.toDouble();
      final lon = (j['lon'] as num?)?.toDouble();
      lastSos = GroupSos(
        (j['name'] as String?) ?? 'Mitfahrer',
        lat != null && lon != null ? RoutePoint(lat, lon) : null,
        now,
      );
    }
    notifyListeners();
  }

  /// Gruppe verlassen: Position bei den anderen loeschen, trennen.
  Future<void> leave() async {
    if (_crypto != null) {
      transport.publish('$_base/pos/$myId', Uint8List(0), retain: true);
    }
    await _sub?.cancel();
    await transport.disconnect();
    started = false;
  }
}

/// Die laufende Gruppenfahrt (eine je App).
class GroupRide {
  GroupRide._();
  static final ValueNotifier<GroupSession?> current = ValueNotifier(null);
}

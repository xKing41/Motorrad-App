import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

/// Chat-Nachricht.
class ChatMessage {
  ChatMessage({
    required this.mid,
    required this.from,
    required this.fromId,
    required this.text,
    required this.at,
  });

  final String mid;
  final String from;
  final String fromId;
  final String text;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'mid': mid,
        'id': fromId,
        'name': from,
        'text': text,
        'ts': at.millisecondsSinceEpoch,
      };

  static ChatMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    final mid = j['mid'], text = j['text'], ts = j['ts'];
    if (mid is! String || text is! String || ts is! num) return null;
    return ChatMessage(
      mid: mid,
      from: (j['name'] as String?) ?? 'Mitfahrer',
      fromId: (j['id'] as String?) ?? '',
      text: text.length > 1000 ? text.substring(0, 1000) : text,
      at: DateTime.fromMillisecondsSinceEpoch(ts.toInt()),
    );
  }
}

/// Geplante Ausfahrt ("Sonntag 10 Uhr, Treffpunkt Tanke Wetter").
class RideEvent {
  RideEvent({
    required this.id,
    required this.title,
    required this.when,
    required this.byName,
    required this.byId,
    this.meet,
    this.meetName,
    this.tour,
    this.tourKm,
  });

  final String id;
  final String title;
  final DateTime when;
  final String byName;
  final String byId;
  final RoutePoint? meet;
  final String? meetName;
  /// Nur beim Anlegen gesetzt; die Linie geht als eigene Nachricht raus
  /// (sonst wird die Liste der Ausfahrten zu gross).
  final RoutePlan? tour;
  final double? tourKm;

  double? get km => tour != null ? tour!.distanceM / 1000 : tourKm;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'when': when.millisecondsSinceEpoch,
        'by': byName,
        'byId': byId,
        if (meet != null) 'lat': meet!.lat,
        if (meet != null) 'lon': meet!.lon,
        if (meetName != null) 'meet': meetName,
        if (km != null) 'km': double.parse(km!.toStringAsFixed(1)),
      };

  static RideEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], title = j['title'], when = j['when'];
    if (id is! String || title is! String || when is! num) return null;
    final lat = (j['lat'] as num?)?.toDouble();
    final lon = (j['lon'] as num?)?.toDouble();
    return RideEvent(
      id: id,
      title: title,
      when: DateTime.fromMillisecondsSinceEpoch(when.toInt()),
      byName: (j['by'] as String?) ?? '',
      byId: (j['byId'] as String?) ?? '',
      meet: lat != null && lon != null ? RoutePoint(lat, lon) : null,
      meetName: j['meet'] as String?,
      tourKm: (j['km'] as num?)?.toDouble(),
    );
  }
}

/// Sprachnachricht aus der Gruppe ("Funkgeraet").
class GroupVoice {
  GroupVoice(this.from, this.audio, this.duration, this.at);
  final String from;
  final Uint8List audio;
  final Duration duration;
  final DateTime at;
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
    this.ownsTransport = true,
    this.name,
    this.shareLive = true,
  });

  final GroupTransport transport;

  /// Eigene Verbindung (sonst teilen sich mehrere Gruppen eine).
  final bool ownsTransport;

  /// Name der Gruppe ("Sauerland-Biker").
  String? name;

  /// Eigene Position teilen (nur waehrend Fahrt/Navigation).
  bool shareLive;

  /// Chat, aelteste zuerst (hoechstens [maxChat]).
  final List<ChatMessage> chat = [];
  static const int maxChat = 200;
  int unread = 0;

  /// Geplante Ausfahrten und Zusagen (Ausfahrt -> Mitglied -> (Name, dabei)).
  final Map<String, RideEvent> rides = {};
  final Map<String, Map<String, (String, bool)>> rsvps = {};

  /// Touren zu den Ausfahrten (kommen einzeln).
  final Map<String, RoutePlan> rideTours = {};

  RoutePlan? tourFor(RideEvent r) => r.tour ?? rideTours[r.id];
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

  /// Die letzten Sprachnachrichten (neueste zuletzt).
  final List<GroupVoice> voices = [];
  final _voiceIn = StreamController<GroupVoice>.broadcast();

  /// Neue Sprachnachricht der anderen - zum sofortigen Abspielen.
  Stream<GroupVoice> get voiceIn => _voiceIn.stream;

  /// Groesste Nachricht (Bytes Audio, ~20 s bei 24 kbit/s).
  static const int maxVoiceBytes = 90 * 1024;
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
    started = true;
    // Geteilte Verbindung baut der GroupHub auf.
    if (ownsTransport && !transport.connected) {
      await transport.connect('sl-$myId');
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------
  //  Community: Name, Chat, Ausfahrten
  // -------------------------------------------------------------------

  static String _newId() => newMemberId();

  /// Gruppenname fuer alle setzen.
  Future<void> setName(String n) async {
    name = n.trim();
    notifyListeners();
    await _publish('meta', {'name': name, 'id': myId}, retain: true);
  }

  /// Chat-Nachricht senden. Die letzten Nachrichten werden zusaetzlich als
  /// Verlauf abgelegt - wer spaeter kommt, sieht sie auch.
  Future<void> sendChat(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final m = ChatMessage(
      mid: _newId(),
      from: myName,
      fromId: myId,
      text: t.length > 1000 ? t.substring(0, 1000) : t,
      at: DateTime.now(),
    );
    _addChat(m);
    notifyListeners();
    await _publish('chat', m.toJson());
    await _publish('history', {
      'msgs': [for (final c in chat.skip(math.max(0, chat.length - 50))) c.toJson()],
    }, retain: true);
  }

  /// Chat wurde angesehen.
  void markRead() {
    if (unread == 0) return;
    unread = 0;
    notifyListeners();
  }

  bool _addChat(ChatMessage m) {
    if (chat.any((c) => c.mid == m.mid)) return false;
    chat.add(m);
    chat.sort((a, b) => a.at.compareTo(b.at));
    while (chat.length > maxChat) {
      chat.removeAt(0);
    }
    return true;
  }

  /// Ausfahrt anlegen oder aendern.
  Future<void> saveRide(RideEvent r) async {
    rides[r.id] = r;
    final t = r.tour;
    if (t != null) rideTours[r.id] = t;
    notifyListeners();
    await _publishRides();
    if (t != null) {
      await _publish('ridetour/${r.id}', {'id': myId, 'plan': planToJson(t)},
          retain: true);
    }
  }

  Future<void> deleteRide(String id) async {
    final hadTour = rideTours.remove(id) != null;
    rides.remove(id);
    notifyListeners();
    await _publishRides();
    // Gespeicherte Tour beim Dienst loeschen (leere Nachricht).
    if (hadTour && _crypto != null && transport.connected) {
      transport.publish('$_base/ridetour/$id', Uint8List(0), retain: true);
    }
  }

  Future<void> _publishRides() async {
    // Vorbei ist vorbei (einen Tag Nachlauf).
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    rides.removeWhere((_, r) => r.when.isBefore(cutoff));
    final list = rides.values.toList()..sort((a, b) => a.when.compareTo(b.when));
    await _publish('rides', {
      'list': [for (final r in list.take(20)) r.toJson()],
    }, retain: true);
  }

  static String newRideId() => _newId();

  /// Zu- oder Absage.
  Future<void> rsvp(String rideId, bool going) async {
    rsvps.putIfAbsent(rideId, () => {})[myId] = (myName, going);
    notifyListeners();
    await _publish('rsvp/$rideId/$myId',
        {'id': myId, 'name': myName, 'going': going},
        retain: true);
  }

  /// Wer ist dabei?
  List<String> going(String rideId) => [
        for (final e in (rsvps[rideId] ?? const {}).values)
          if (e.$2) e.$1,
      ];

  bool? myRsvp(String rideId) => rsvps[rideId]?[myId]?.$2;

  List<RideEvent> get upcoming {
    final cutoff = DateTime.now().subtract(const Duration(hours: 12));
    return rides.values.where((r) => r.when.isAfter(cutoff)).toList()
      ..sort((a, b) => a.when.compareTo(b.when));
  }

  // Ohne Verbindung Geschriebenes (Chat, Zusagen) wartet hier.
  final List<(String, Map<String, dynamic>, bool)> _outbox = [];

  Future<void> _publish(String sub, Map<String, dynamic> json,
      {bool retain = false}) async {
    final c = _crypto;
    if (c == null) return;
    if (!transport.connected) {
      // Positionen und Funk sind nach Sekunden wertlos - die nicht.
      if (sub.startsWith('pos/') || sub == 'voice' || sub == 'sos') return;
      _outbox.removeWhere((o) => o.$3 && o.$1 == sub && retain);
      _outbox.add((sub, json, retain));
      if (_outbox.length > 50) _outbox.removeAt(0);
      return;
    }
    transport.publish('$_base/$sub', await c.seal(json), retain: retain);
  }

  /// Verbindung steht (wieder): Wartendes senden.
  Future<void> flush() async {
    if (!transport.connected) return;
    final out = [..._outbox];
    _outbox.clear();
    for (final (sub, json, retain) in out) {
      await _publish(sub, json, retain: retain);
    }
  }

  int get pending => _outbox.length;

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

  /// Sprachnachricht an alle (nicht gespeichert: wer spaeter dazukommt,
  /// hoert sie nicht - wie beim Funkgeraet).
  Future<bool> sendVoice(Uint8List audio, Duration duration) async {
    if (audio.isEmpty || audio.length > maxVoiceBytes) return false;
    await _publish('voice', {
      'id': myId,
      'name': myName,
      'ms': duration.inMilliseconds,
      'a': base64Encode(audio),
    });
    return true;
  }

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
      } else if (sub.startsWith('ridetour/')) {
        rideTours.remove(sub.substring(9));
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
    } else if (sub == 'meta') {
      final n = j['name'];
      if (n is String && n.trim().isNotEmpty) name = n.trim();
    } else if (sub == 'chat') {
      final m = ChatMessage.fromJson(j);
      if (m != null && _addChat(m) && m.fromId != myId) unread++;
    } else if (sub == 'history') {
      for (final x in (j['msgs'] as List? ?? const [])) {
        final m = ChatMessage.fromJson(x);
        if (m != null) _addChat(m);
      }
    } else if (sub == 'rides') {
      final list = j['list'];
      if (list is List) {
        rides
          ..clear()
          ..addAll({
            for (final x in list)
              if (RideEvent.fromJson(x) case final r?) r.id: r,
          });
      }
    } else if (sub.startsWith('ridetour/')) {
      final p = planFromJson(j['plan']);
      if (p == null) return;
      rideTours[sub.substring(9)] = p;
    } else if (sub.startsWith('rsvp/')) {
      final parts = sub.split('/');
      if (parts.length != 3) return;
      rsvps.putIfAbsent(parts[1], () => {})[parts[2]] =
          ((j['name'] as String?) ?? 'Mitfahrer', j['going'] == true);
    } else if (sub == 'voice') {
      if (id == myId) return;
      final a = j['a'];
      if (a is! String) return;
      final Uint8List audio;
      try {
        audio = base64Decode(a);
      } catch (_) {
        return;
      }
      if (audio.isEmpty || audio.length > maxVoiceBytes) return;
      final v = GroupVoice(
        (j['name'] as String?) ?? 'Mitfahrer',
        audio,
        Duration(milliseconds: (j['ms'] as num?)?.toInt() ?? 0),
        now,
      );
      voices.add(v);
      if (voices.length > 10) voices.removeAt(0);
      _voiceIn.add(v);
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
    if (ownsTransport) await transport.disconnect();
    started = false;
  }
}

/// Alle Gruppen dieses Handys - dauerhaft gemerkt, beim App-Start
/// automatisch wieder verbunden, bis man ausdruecklich austritt.
class GroupHub extends ChangeNotifier {
  GroupHub({GroupTransport Function()? transport})
      : _makeTransport = transport ?? MqttTransport.new;

  static final GroupHub instance = GroupHub();

  final GroupTransport Function() _makeTransport;
  GroupTransport? _transport;
  final List<GroupSession> sessions = [];
  String? myId;
  String myName = 'Fahrer';
  bool restored = false;

  static const _kGroups = 'groups_v1';
  static const _kMyId = 'group_my_id';

  GroupTransport get _t => _transport ??= _makeTransport();

  /// Verbindung zum Gruppendienst steht.
  bool get online => _transport?.connected ?? false;

  /// App im Hintergrund und keine Fahrt: Verbindung ruht (Akku).
  bool _paused = false;
  Future<void>? _connecting;
  Timer? _retry;
  int _fails = 0;

  /// Verbindung aufbauen; klappt es nicht, spaeter erneut (30 s bis 5 min).
  Future<void> _connect() {
    if (sessions.isEmpty || _paused) return Future.value();
    final t = _t;
    if (t.connected) return Future.value();
    return _connecting ??= () async {
      try {
        await t.connect('sl-${myId ?? GroupSession.newMemberId()}');
        _fails = 0;
        for (final s in [...sessions]) {
          s.error = null;
          await s.flush();
        }
      } catch (_) {
        _fails++;
        for (final s in sessions) {
          s.error = 'Keine Verbindung - wird wiederholt';
        }
        _retry?.cancel();
        _retry = Timer(
            Duration(seconds: math.min(300, 30 * _fails)), () => _connect());
      } finally {
        _connecting = null;
        notifyListeners();
      }
    }();
  }

  /// App geht in den Hintergrund (ohne laufende Fahrt).
  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    _retry?.cancel();
    await _transport?.disconnect();
    notifyListeners();
  }

  /// App wieder vorne: neu verbinden (gespeicherte Nachrichten kommen nach).
  Future<void> resume() async {
    if (!_paused) return;
    _paused = false;
    _fails = 0;
    await _connect();
  }

  GroupSession? byCode(String code) {
    for (final s in sessions) {
      if (s.code == code) return s;
    }
    return null;
  }

  /// Gemerkte Gruppen wieder verbinden (beim App-Start).
  Future<void> restore(String name) async {
    if (restored) return;
    restored = true;
    myName = name;
    await _ensureId();
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kGroups);
    if (raw == null) return;
    try {
      for (final g in (jsonDecode(raw) as List).whereType<Map>()) {
        final code = g['code'];
        if (code is! String) continue;
        await _open(code,
            name: g['name'] as String?, shareLive: g['live'] != false);
      }
    } catch (_) {
      // kaputter Speicher: ohne Gruppen weiter
    }
    notifyListeners();
    await _connect();
  }

  Future<void> _ensureId() async {
    if (myId != null) return;
    final sp = await SharedPreferences.getInstance();
    myId = sp.getString(_kMyId) ?? GroupSession.newMemberId();
    await sp.setString(_kMyId, myId!);
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _kGroups,
        jsonEncode([
          for (final s in sessions)
            {'code': s.code, 'name': s.name, 'live': s.shareLive},
        ]));
  }

  Future<GroupSession> _open(String code,
      {String? name, bool shareLive = true}) async {
    final existing = byCode(code);
    if (existing != null) return existing;
    final s = GroupSession(
      transport: _t,
      code: code,
      myId: myId ?? GroupSession.newMemberId(),
      myName: myName,
      ownsTransport: false,
      name: name,
      shareLive: shareLive,
    );
    s.addListener(_changed);
    sessions.add(s);
    await s.start();
    return s;
  }

  void _changed() => notifyListeners();

  /// Neue Gruppe gruenden.
  Future<GroupSession> create(String name) async {
    await _ensureId();
    final s = await _open(GroupSession.newCode(), name: name);
    await _connect();
    await s.setName(name);
    await _save();
    notifyListeners();
    return s;
  }

  /// Mit Code beitreten.
  Future<GroupSession> join(String code) async {
    await _ensureId();
    final s = await _open(code);
    await _connect();
    await _save();
    notifyListeners();
    return s;
  }

  /// Austreten (fuer immer - nicht beim Schliessen der App).
  Future<void> leave(GroupSession s) async {
    sessions.remove(s);
    s.removeListener(_changed);
    await s.leave();
    await _save();
    if (sessions.isEmpty) {
      _retry?.cancel();
      await _transport?.disconnect();
      _transport = null;
    }
    notifyListeners();
  }

  Future<void> setShareLive(GroupSession s, bool on) async {
    s.shareLive = on;
    await _save();
    notifyListeners();
  }

  Future<void> rename(GroupSession s, String name) async {
    await s.setName(name);
    await _save();
  }

  /// Position an alle Gruppen, die sie bekommen sollen.
  Future<void> sendPosition(double lat, double lon, double speedMs) async {
    for (final s in sessions) {
      if (s.shareLive && s.started) await s.sendPosition(lat, lon, speedMs);
    }
  }

  Future<void> sendSos(double? lat, double? lon) async {
    // Notfall: auch aus der Ruhe heraus sofort verbinden.
    _paused = false;
    await _connect();
    for (final s in sessions) {
      if (s.started) await s.sendSos(lat, lon);
    }
  }

  /// Sprachnachricht an alle Gruppen mit Live-Teilen (Fahrgruppen).
  Future<bool> sendVoice(Uint8List audio, Duration d) async {
    var ok = false;
    for (final s in sessions) {
      if (s.shareLive && s.started) ok = await s.sendVoice(audio, d) || ok;
    }
    return ok;
  }

  /// Mitfahrer aus allen Gruppen (jeder nur einmal).
  List<GroupMember> get members {
    final out = <String, GroupMember>{};
    for (final s in sessions) {
      for (final m in s.members.values) {
        final o = out[m.id];
        if (o == null || m.seen.isAfter(o.seen)) out[m.id] = m;
      }
    }
    return out.values.toList();
  }

  int get unread => sessions.fold(0, (a, s) => a + s.unread);
}

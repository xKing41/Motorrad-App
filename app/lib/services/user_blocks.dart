import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_plan.dart';
import 'geo.dart';
import 'road_check.dart';
import 'routing_engine.dart';

// ---------------------------------------------------------------------------
//  EIGENE SPERRLISTE
//
//  Die Karte weiss nicht alles: ein neues Verbotsschild, ein Weg, der in
//  Wahrheit ein Feldweg ist, eine Dauerbaustelle. Hier merkt sich die App
//  Stellen, die der Fahrer selbst gesperrt hat. Jede Routenberechnung
//  (Planen, Bearbeiten, Neuberechnung unterwegs, auch ohne Netz) meidet
//  die Strasse an diesen Stellen.
// ---------------------------------------------------------------------------

class UserBlock {
  const UserBlock(this.id, this.point, this.label, this.created);
  final String id;
  final RoutePoint point;
  final String label;
  final DateTime created;

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': point.lat,
        'lon': point.lon,
        'label': label,
        'ts': created.millisecondsSinceEpoch,
      };

  static UserBlock? fromJson(Object? j) {
    if (j is! Map) return null;
    final lat = j['lat'], lon = j['lon'];
    if (lat is! num || lon is! num) return null;
    return UserBlock(
      '${j['id'] ?? '${lat}_$lon'}',
      RoutePoint(lat.toDouble(), lon.toDouble()),
      (j['label'] as String?) ?? 'Gesperrt',
      DateTime.fromMillisecondsSinceEpoch((j['ts'] as num?)?.toInt() ?? 0),
    );
  }
}

class UserBlocks extends ChangeNotifier {
  UserBlocks();
  static final UserBlocks instance = UserBlocks();

  static const _key = 'user_blocks_v1';

  /// Die Strasse gilt in diesem Umkreis um den Punkt als gesperrt.
  static const double radiusM = 35;

  final List<UserBlock> blocks = [];
  bool _loaded = false;

  List<RoutePoint> get points => [for (final b in blocks) b.point];

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw != null) {
      try {
        blocks
          ..clear()
          ..addAll([
            for (final x in jsonDecode(raw) as List)
              if (UserBlock.fromJson(x) case final b?) b,
          ]);
      } catch (_) {
        // kaputter Speicher: leer weiter
      }
    }
    _register();
    notifyListeners();
  }

  /// Jede Routing-Anfrage meidet die Sperren.
  void _register() {
    RoutingEngine.globalAvoid = () => points;
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode([for (final b in blocks) b.toJson()]));
  }

  Future<UserBlock> add(RoutePoint p, String label) async {
    final b = UserBlock(
        '${DateTime.now().microsecondsSinceEpoch}', p, label.trim().isEmpty
            ? 'Gesperrt'
            : label.trim(), DateTime.now());
    blocks.add(b);
    _register();
    notifyListeners();
    await _save();
    return b;
  }

  /// Aus einer Sicherung (gleiche Sperre nicht doppelt).
  Future<void> addExisting(UserBlock b) async {
    if (blocks.any((x) => x.id == b.id || dist(x.point, b.point) < 5)) return;
    blocks.add(b);
    _register();
    notifyListeners();
    await _save();
  }

  Future<void> remove(String id) async {
    blocks.removeWhere((b) => b.id == id);
    notifyListeners();
    await _save();
  }

  /// Sperre in der Naehe von [p] (zum Aufheben per Tipp auf die Karte).
  UserBlock? near(RoutePoint p, {double withinM = 60}) {
    UserBlock? best;
    var bestD = withinM;
    for (final b in blocks) {
      final d = dist(b.point, p);
      if (d <= bestD) {
        best = b;
        bestD = d;
      }
    }
    return best;
  }
}

/// Prueft, ob die Route ueber eine selbst gesperrte Stelle fuehrt.
class UserBlockCheck extends RoadCheck {
  UserBlockCheck([UserBlocks? blocks]) : _blocks = blocks ?? UserBlocks.instance;
  final UserBlocks _blocks;

  @override
  String get name => 'eigene Sperren';

  @override
  Future<List<RoadIssue>> check(List<RoutePoint> pts,
      {bool unpaved = true}) async {
    if (pts.length < 2 || _blocks.blocks.isEmpty) return const [];
    final cum = cumulativeDistances(pts);
    final out = <RoadIssue>[];
    for (final b in _blocks.blocks) {
      final hit = projectOnPolyline(b.point, pts, cum);
      if (hit == null || hit.distanceM > UserBlocks.radiusM) continue;
      out.add(RoadIssue(
          (hit.alongM - 50).clamp(0.0, cum.last),
          (hit.alongM + 50).clamp(0.0, cum.last),
          'von dir gesperrt (${b.label})'));
    }
    return out;
  }
}

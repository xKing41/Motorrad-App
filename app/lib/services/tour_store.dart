import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/route_plan.dart';
import 'geo.dart';

// ---------------------------------------------------------------------------
//  GESPEICHERTE TOUREN
//
//  Eine gelungene Tour will man wieder fahren oder erst am Wochenende.
//  Gespeichert wird die komplette Route - Linie, Abbiegehinweise, Stopps
//  und die Vorgaben, aus denen sie entstand. Beim Laden wird nichts neu
//  berechnet: Die Tour ist genau dieselbe, auch ohne Netz. Die Vorgaben
//  braucht die Navigation fuer Neuberechnungen unterwegs (z. B. weiter
//  ohne Autobahn).
// ---------------------------------------------------------------------------

/// Kurzinfo fuer die Liste.
class TourMeta {
  const TourMeta({
    required this.id,
    required this.title,
    required this.savedAt,
    required this.distanceM,
    required this.durationSec,
    required this.roundTrip,
    this.curvLabel,
  });

  final String id;
  final String title;
  final DateTime savedAt;
  final double distanceM;
  final int durationSec;
  final bool roundTrip;
  final String? curvLabel;

  bool get isLast => id == TourStore.lastId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'saved': savedAt.millisecondsSinceEpoch,
        'dist': distanceM,
        'dur': durationSec,
        'loop': roundTrip,
        if (curvLabel != null) 'curv': curvLabel,
      };

  static TourMeta? fromJson(Object? o) {
    if (o is! Map<String, dynamic> || o['id'] is! String) return null;
    return TourMeta(
      id: o['id'] as String,
      title: o['title'] as String? ?? 'Tour',
      savedAt: DateTime.fromMillisecondsSinceEpoch(
          (o['saved'] as num?)?.toInt() ?? 0),
      distanceM: (o['dist'] as num?)?.toDouble() ?? 0,
      durationSec: (o['dur'] as num?)?.toInt() ?? 0,
      roundTrip: o['loop'] as bool? ?? false,
      curvLabel: o['curv'] as String?,
    );
  }

  TourMeta renamed(String t) => TourMeta(
        id: id,
        title: t,
        savedAt: savedAt,
        distanceM: distanceM,
        durationSec: durationSec,
        roundTrip: roundTrip,
        curvLabel: curvLabel,
      );
}

/// Route <-> JSON. Die Linie wird kompakt als Polyline gespeichert
/// (Genauigkeit 1e-6 Grad, rund 10 cm) - eine 300-km-Tour braucht so
/// etwa 100 KB statt eines Megabytes.
Map<String, dynamic> planToJson(RoutePlan p) => {
      'v': 1,
      'line': encodePolyline(p.points),
      'dist': p.distanceM,
      'dur': p.durationSec,
      'steps': [for (final s in p.steps) s.toJson()],
      'pois': [for (final x in p.pois) x.toJson()],
      if (p.title != null) 'title': p.title,
      if (p.description != null) 'desc': p.description,
      if (p.stats != null) 'stats': p.stats!.toJson(),
      if (p.engineLabel != null) 'engine': p.engineLabel,
      if (p.notes.isNotEmpty) 'notes': p.notes,
      'loop': p.roundTrip,
      if (p.request != null) 'req': p.request!.toStorage(),
    };

RoutePlan? planFromJson(Object? o) {
  if (o is! Map<String, dynamic>) return null;
  final line = o['line'];
  if (line is! String) return null;
  final pts = decodePolyline(line);
  if (pts.length < 2) return null;
  List<Map<String, dynamic>> maps(String k) =>
      ((o[k] as List?) ?? const []).whereType<Map<String, dynamic>>().toList();
  return RoutePlan(
    points: pts,
    distanceM: (o['dist'] as num?)?.toDouble() ?? pathLength(pts),
    durationSec: (o['dur'] as num?)?.toInt() ?? 0,
    steps: [
      for (final s in maps('steps'))
        if (RouteStep.fromJson(s) case final st
            when st.pointIndex >= 0 && st.pointIndex < pts.length)
          st,
    ],
    pois: [
      for (final x in maps('pois'))
        if (x['id'] is String && x['lat'] is num && x['lon'] is num)
          Poi.fromJson(x),
    ],
    title: o['title'] as String?,
    description: o['desc'] as String?,
    stats: o['stats'] is Map<String, dynamic>
        ? RouteStats.fromJson(o['stats'] as Map<String, dynamic>)
        : null,
    engineLabel: o['engine'] as String?,
    notes: [for (final n in (o['notes'] as List?) ?? const []) '$n'],
    roundTrip: o['loop'] as bool? ?? false,
    request: o['req'] is Map<String, dynamic>
        ? RouteRequest.fromStorage(o['req'] as Map<String, dynamic>)
        : null,
  );
}

class TourStore {
  TourStore(this.dir);

  /// Die zuletzt geplante oder geladene Route - automatisch gesichert,
  /// damit sie einen App-Neustart uebersteht.
  static const lastId = 'last';

  final Directory dir;

  static TourStore? _instance;
  static Future<TourStore> open() async {
    final i = _instance;
    if (i != null) return i;
    final base = await getApplicationDocumentsDirectory();
    return _instance = TourStore(Directory('${base.path}/tours'));
  }

  File get _index => File('${dir.path}/index.json');
  File _file(String id) => File('${dir.path}/$id.json');

  static Future<void> _writeAtomic(File f, String content) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }

  /// Alle Touren, neueste zuerst; die zuletzt benutzte Route oben.
  Future<List<TourMeta>> list() async {
    List<TourMeta> out;
    try {
      final raw = jsonDecode(await _index.readAsString());
      out = [
        for (final o in (raw is List ? raw : const []))
          if (TourMeta.fromJson(o) case final m?) m,
      ];
    } catch (_) {
      out = await _rebuildIndex();
    }
    out.sort((a, b) {
      if (a.isLast != b.isLast) return a.isLast ? -1 : 1;
      return b.savedAt.compareTo(a.savedAt);
    });
    return out;
  }

  /// Index kaputt oder weg: aus den Tourdateien neu aufbauen.
  Future<List<TourMeta>> _rebuildIndex() async {
    final out = <TourMeta>[];
    if (!await dir.exists()) return out;
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      final name = e.uri.pathSegments.last;
      if (name == 'index.json') continue;
      try {
        final j = jsonDecode(await e.readAsString());
        final m = TourMeta.fromJson(j is Map ? j['meta'] : null);
        if (m != null) out.add(m);
      } catch (_) {
        // defekte Datei ueberspringen
      }
    }
    await _saveIndex(out);
    return out;
  }

  Future<void> _saveIndex(List<TourMeta> l) =>
      _writeAtomic(_index, jsonEncode([for (final m in l) m.toJson()]));

  static String _newId() => 't${DateTime.now().microsecondsSinceEpoch}';

  /// Speichert eine Tour. Mit [id] wird eine bestehende ersetzt.
  Future<TourMeta> save(RoutePlan plan,
      {String? title, String? id, DateTime? savedAt}) async {
    final meta = TourMeta(
      id: id ?? _newId(),
      title: (title ?? plan.title ?? '').trim().isEmpty
          ? 'Tour ${(plan.distanceM / 1000).round()} km'
          : (title ?? plan.title)!.trim(),
      savedAt: savedAt ?? DateTime.now(),
      distanceM: plan.distanceM,
      durationSec: plan.durationSec,
      roundTrip: plan.roundTrip,
      curvLabel: plan.stats?.curvLabel,
    );
    await _writeAtomic(_file(meta.id),
        jsonEncode({'meta': meta.toJson(), 'plan': planToJson(plan)}));
    final l = (await list()).where((m) => m.id != meta.id).toList()
      ..add(meta);
    await _saveIndex(l);
    return meta;
  }

  /// Merkt sich die aktuelle Route (ueberschreibt die vorige).
  Future<void> saveLast(RoutePlan plan) => save(plan, id: lastId);

  Future<RoutePlan?> load(String id) async {
    try {
      final j = jsonDecode(await _file(id).readAsString());
      if (j is! Map) return null;
      return planFromJson(j['plan']);
    } catch (_) {
      return null;
    }
  }

  Future<void> rename(String id, String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    final l = await list();
    final i = l.indexWhere((m) => m.id == id);
    if (i < 0) return;
    l[i] = l[i].renamed(t);
    await _saveIndex(l);
    // Auch in der Tourdatei, damit ein neu aufgebauter Index stimmt.
    try {
      final f = _file(id);
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      j['meta'] = l[i].toJson();
      await _writeAtomic(f, jsonEncode(j));
    } catch (_) {
      // Index ist aktualisiert - das reicht fuer die Anzeige.
    }
  }

  Future<void> delete(String id) async {
    final l = (await list()).where((m) => m.id != id).toList();
    await _saveIndex(l);
    try {
      await _file(id).delete();
    } on FileSystemException {
      // schon weg
    }
  }
}

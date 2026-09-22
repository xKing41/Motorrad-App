import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/ride.dart';
import '../models/route_plan.dart';

/// Import und Export von GPX-Dateien.
///
/// Der Parser ist bewusst schlank gehalten (kein zusaetzliches XML-Paket):
/// GPX besteht im Kern aus <trkpt>, <rtept> und <wpt> mit lat/lon-Attributen.
/// Das deckt praktisch alle Dateien ab, die Navis und Tourenplaner ausgeben.
class GpxService {
  static final RegExp _ptRe = RegExp(
    r'<(trkpt|rtept)\b([^>]*)>',
    caseSensitive: false,
  );
  static final RegExp _wptRe = RegExp(
    r'<wpt\b([^>]*?)(/>|>(.*?)</wpt>)',
    caseSensitive: false,
    dotAll: true,
  );
  // Attribute in beliebiger Reihenfolge und mit ' oder " - vorher wurde
  // nur lat="..." VOR lon="..." erkannt, und manche Programme schreiben
  // es andersherum.
  static final RegExp _latRe =
      RegExp(r'''\blat\s*=\s*["']([-+0-9.eE]+)["']''', caseSensitive: false);
  static final RegExp _lonRe =
      RegExp(r'''\blon\s*=\s*["']([-+0-9.eE]+)["']''', caseSensitive: false);
  static final RegExp _nameRe =
      RegExp(r'<name>(.*?)</name>', caseSensitive: false, dotAll: true);

  static RoutePoint? _point(String attrs) {
    final lat = double.tryParse(_latRe.firstMatch(attrs)?.group(1) ?? '');
    final lon = double.tryParse(_lonRe.firstMatch(attrs)?.group(1) ?? '');
    if (lat == null || lon == null) return null;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return RoutePoint(lat, lon);
  }

  /// Liest eine GPX-Datei als Route ein.
  ///
  /// Track-Punkte haben Vorrang vor Routenpunkten (ein Track ist die
  /// genaue Linie, eine Route oft nur grobe Stuetzpunkte). Wegpunkte
  /// werden als Markierungen uebernommen und NICHT mehr in die Linie
  /// gemischt - vorher sprang die Route dadurch kreuz und quer.
  static RoutePlan parseRoute(String xml, {String? fallbackTitle}) {
    final trk = <RoutePoint>[];
    final rte = <RoutePoint>[];
    for (final m in _ptRe.allMatches(xml)) {
      final p = _point(m.group(2) ?? '');
      if (p == null) continue;
      if (m.group(1)!.toLowerCase() == 'trkpt') {
        trk.add(p);
      } else {
        rte.add(p);
      }
    }

    final pois = <Poi>[];
    final wptPoints = <RoutePoint>[];
    var n = 0;
    for (final m in _wptRe.allMatches(xml)) {
      final p = _point(m.group(1) ?? '');
      if (p == null) continue;
      wptPoints.add(p);
      final name = _nameRe.firstMatch(m.group(3) ?? '')?.group(1);
      pois.add(Poi(
        id: 'gpx_${n++}',
        kind: PoiKind.rest,
        lat: p.lat,
        lon: p.lon,
        name: name != null ? _unescape(name.trim()) : null,
        detail: 'Wegpunkt aus GPX',
        source: 'gpx',
      ));
    }

    // Nur Wegpunkte in der Datei: dann bilden eben die die Linie.
    final pts = trk.isNotEmpty ? trk : (rte.isNotEmpty ? rte : wptPoints);

    double dist = 0;
    for (var i = 1; i < pts.length; i++) {
      dist += distanceMeters(
          pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    }

    return RoutePlan(
      points: pts,
      distanceM: dist,
      pois: identical(pts, wptPoints) ? const [] : pois,
      title: _title(xml) ?? fallbackTitle ?? 'Importierte Route',
    );
  }

  /// Name der Tour: bevorzugt aus Track, Route oder Metadaten - nicht
  /// der Name des ersten Wegpunkts.
  static String? _title(String xml) {
    for (final tag in ['trk', 'rte', 'metadata']) {
      final block = RegExp('<$tag\\b.*?</$tag>',
              caseSensitive: false, dotAll: true)
          .firstMatch(xml)
          ?.group(0);
      if (block == null) continue;
      final name = _nameRe.firstMatch(block)?.group(1);
      if (name != null && name.trim().isNotEmpty) {
        return _unescape(name.trim());
      }
    }
    final any = _nameRe.firstMatch(xml)?.group(1)?.trim();
    return (any == null || any.isEmpty) ? null : _unescape(any);
  }

  static String _unescape(String s) {
    var t = s;
    final cdata = RegExp(r'^<!\[CDATA\[(.*)\]\]>$', dotAll: true).firstMatch(t);
    if (cdata != null) return cdata.group(1)!.trim();
    t = t
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
    return t;
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Eigener Namensraum fuer Schraeglage und Tempo. Ohne Namensraum ist
  /// die Datei streng genommen kein gueltiges GPX 1.1, und penible
  /// Programme lehnen sie ab.
  static const _ns = 'https://schraeglage.app/xmlns/gpx/1';

  /// Schreibt eine aufgezeichnete Fahrt als GPX.
  /// Die Schraeglage wird als Extension mitgeschrieben, damit sie beim
  /// Re-Import nicht verloren geht.
  static String trackToGpx(RideSummary ride, List<TrackPoint> track) {
    final trackName = _escape(ride.title ?? 'Fahrt ${ride.id}');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="Schraeglage" '
          'xmlns="http://www.topografix.com/GPX/1/1" xmlns:sl="$_ns">')
      ..writeln('  <trk>')
      ..writeln('    <name>$trackName</name>')
      ..writeln('    <trkseg>');

    for (final p in track) {
      final t = DateTime.fromMillisecondsSinceEpoch(p.tMs, isUtc: true)
          .toIso8601String();
      b.writeln('      <trkpt lat="${p.lat.toStringAsFixed(6)}" '
          'lon="${p.lon.toStringAsFixed(6)}">');
      // Reihenfolge laut GPX-Schema: ele vor time.
      if (p.altM != null) {
        b.writeln('        <ele>${p.altM!.toStringAsFixed(1)}</ele>');
      }
      b
        ..writeln('        <time>$t</time>')
        ..writeln('        <extensions>')
        ..writeln('          <sl:lean>${p.lean.toStringAsFixed(1)}</sl:lean>')
        ..writeln(
            '          <sl:speed>${p.speedMs.toStringAsFixed(2)}</sl:speed>')
        ..writeln('        </extensions>')
        ..writeln('      </trkpt>');
    }

    b
      ..writeln('    </trkseg>')
      ..writeln('  </trk>')
      ..writeln('</gpx>');
    return b.toString();
  }

  /// Schreibt eine geplante Route als GPX (fuer Export ans Navi).
  ///
  /// Als TRACK, nicht als Route: Eine Route mit tausenden Punkten
  /// lehnen viele Navis ab oder berechnen sie neu - und dann ist die
  /// sorgfaeltig ausgesuchte kurvige Strecke weg. Stopps kommen als
  /// Wegpunkte dazu.
  static String routeToGpx(RoutePlan plan) {
    final routeName = _escape(plan.title ?? 'Route');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="Schraeglage" '
          'xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <metadata><name>$routeName</name></metadata>');

    for (final poi in plan.pois) {
      b
        ..writeln('  <wpt lat="${poi.lat.toStringAsFixed(6)}" '
            'lon="${poi.lon.toStringAsFixed(6)}">')
        ..writeln('    <name>${_escape(poi.displayName)}</name>');
      final desc = [poi.kind.label, poi.detail, poi.note]
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .join(' · ');
      if (desc.isNotEmpty) b.writeln('    <desc>${_escape(desc)}</desc>');
      b.writeln('  </wpt>');
    }

    b
      ..writeln('  <trk>')
      ..writeln('    <name>$routeName</name>')
      ..writeln('    <trkseg>');
    for (final p in plan.points) {
      b.writeln('      <trkpt lat="${p.lat.toStringAsFixed(6)}" '
          'lon="${p.lon.toStringAsFixed(6)}"/>');
    }
    b
      ..writeln('    </trkseg>')
      ..writeln('  </trk>')
      ..writeln('</gpx>');
    return b.toString();
  }

  static String safeFileName(String name) {
    var s = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    s = s.replaceAll(RegExp(r'_+'), '_');
    if (s.startsWith('_')) s = s.substring(1);
    return s.isEmpty ? 'route.gpx' : s;
  }

  /// Legt eine GPX-Datei im Dokumentenordner der App ab und gibt den Pfad zurueck.
  static Future<String> writeToFile(String filename, String content) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/export');
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File('${dir.path}/${safeFileName(filename)}');
    await f.writeAsString(content);
    return f.path;
  }

  /// Oeffnet den Teilen-Dialog des Handys mit der GPX-Datei - so landet
  /// sie in WhatsApp, Drive, der Navi-App oder per Mail beim PC.
  ///
  /// Vorher lag die Datei nur im internen App-Ordner, an den man ohne
  /// Root-Rechte gar nicht herankommt.
  ///
  /// Rueckgabe: null bei Erfolg, sonst ein Hinweistext.
  static Future<String?> share(String filename, String content,
      {String? subject}) async {
    final path = await writeToFile(filename, content);
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path, mimeType: 'application/gpx+xml')],
        subject: subject,
        title: subject,
      ));
      return null;
    } catch (_) {
      return 'Teilen nicht möglich - Datei liegt unter $path';
    }
  }
}

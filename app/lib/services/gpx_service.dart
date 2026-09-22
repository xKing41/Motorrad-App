import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/ride.dart';
import '../models/route_plan.dart';

/// Import und Export von GPX-Dateien.
///
/// Der Parser ist bewusst schlank gehalten (kein zusaetzliches XML-Paket):
/// GPX besteht im Kern aus <trkpt>, <rtept> und <wpt> mit lat/lon-Attributen.
/// Das deckt praktisch alle Dateien ab, die Navis und Tourenplaner ausgeben.
class GpxService {
  static final RegExp _ptRe = RegExp(
    r'<(trkpt|rtept|wpt)\b[^>]*?lat\s*=\s*"([-\d.]+)"[^>]*?lon\s*=\s*"([-\d.]+)"',
    caseSensitive: false,
  );
  static final RegExp _nameRe =
      RegExp(r'<name>(.*?)</name>', caseSensitive: false, dotAll: true);

  /// Liest alle Punkte einer GPX-Datei als Route ein.
  static RoutePlan parseRoute(String xml, {String? fallbackTitle}) {
    final pts = <RoutePoint>[];
    for (final m in _ptRe.allMatches(xml)) {
      final lat = double.tryParse(m.group(2) ?? '');
      final lon = double.tryParse(m.group(3) ?? '');
      if (lat == null || lon == null) continue;
      if (lat.abs() > 90 || lon.abs() > 180) continue;
      pts.add(RoutePoint(lat, lon));
    }

    double dist = 0;
    for (var i = 1; i < pts.length; i++) {
      dist += distanceMeters(
          pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
    }

    final nameMatch = _nameRe.firstMatch(xml);
    final title = nameMatch != null
        ? _unescape(nameMatch.group(1)!.trim())
        : (fallbackTitle ?? 'Importierte Route');

    return RoutePlan(
      points: pts,
      distanceM: dist,
      title: title.isEmpty ? 'Importierte Route' : title,
    );
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Schreibt eine aufgezeichnete Fahrt als GPX.
  /// Die Schraeglage wird als Extension mitgeschrieben, damit sie beim
  /// Re-Import nicht verloren geht.
  static String trackToGpx(RideSummary ride, List<TrackPoint> track) {
    final trackName = _escape(ride.title ?? 'Fahrt ${ride.id}');
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="Schraeglage" '
          'xmlns="http://www.topografix.com/GPX/1/1">')
      ..writeln('  <trk>')
      ..writeln('    <name>$trackName</name>')
      ..writeln('    <trkseg>');

    for (final p in track) {
      final t = DateTime.fromMillisecondsSinceEpoch(p.tMs, isUtc: true)
          .toIso8601String();
      b
        ..writeln('      <trkpt lat="${p.lat.toStringAsFixed(6)}" '
            'lon="${p.lon.toStringAsFixed(6)}">')
        ..writeln('        <time>$t</time>');
      if (p.altM != null) {
        b.writeln('        <ele>${p.altM!.toStringAsFixed(1)}</ele>');
      }
      b
        ..writeln('        <extensions>')
        ..writeln('          <lean>${p.lean.toStringAsFixed(1)}</lean>')
        ..writeln('          <speed>${p.speedMs.toStringAsFixed(2)}</speed>')
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
  static String routeToGpx(RoutePlan plan) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="Schraeglage" '
          'xmlns="http://www.topografix.com/GPX/1/1">');

    for (final poi in plan.pois) {
      b
        ..writeln('  <wpt lat="${poi.lat.toStringAsFixed(6)}" '
            'lon="${poi.lon.toStringAsFixed(6)}">')
        ..writeln('    <name>${_escape(poi.displayName)}</name>')
        ..writeln('  </wpt>');
    }

    final routeName = _escape(plan.title ?? 'Route');
    b
      ..writeln('  <rte>')
      ..writeln('    <name>$routeName</name>');
    for (final p in plan.points) {
      b.writeln('    <rtept lat="${p.lat.toStringAsFixed(6)}" '
          'lon="${p.lon.toStringAsFixed(6)}" />');
    }
    b
      ..writeln('  </rte>')
      ..writeln('</gpx>');
    return b.toString();
  }

  /// Legt eine GPX-Datei im Dokumentenordner der App ab und gibt den Pfad zurueck.
  static Future<String> writeToFile(String filename, String content) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/export');
    if (!await dir.exists()) await dir.create(recursive: true);
    final safe = filename.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final f = File('${dir.path}/$safe');
    await f.writeAsString(content);
    return f.path;
  }
}

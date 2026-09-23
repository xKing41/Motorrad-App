import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/ride.dart';
import 'ride_store.dart';
import 'tour_store.dart';

// ---------------------------------------------------------------------------
//  SICHERUNG
//
//  Fahrten und Touren liegen nur auf dem Handy. Geht es verloren oder
//  kommt ein neues, war bisher alles weg. Die Sicherung packt alles in
//  EINE Datei (gzip-komprimiert, eine Zeile je Fahrt/Tour), die man per
//  Teilen-Dialog in Google Drive, per Mail oder auf den PC legt - und auf
//  dem neuen Handy wieder einspielt.
//
//  Zeile fuer Zeile geschrieben und gelesen: auch hunderte Fahrten mit
//  Zehntausenden Punkten passen so in wenig Arbeitsspeicher.
//
//  NICHT enthalten: Schluessel fuer TomTom, HERE, KI - die Datei landet
//  womoeglich in einer Cloud, Schluessel gehoeren da nicht hinein.
// ---------------------------------------------------------------------------

class BackupResult {
  BackupResult({this.rides = 0, this.tours = 0, this.skipped = 0});
  int rides;
  int tours;

  /// Beim Einspielen: schon vorhanden oder unlesbar.
  int skipped;

  String get text {
    final parts = <String>[
      '$rides ${rides == 1 ? 'Fahrt' : 'Fahrten'}',
      '$tours ${tours == 1 ? 'Tour' : 'Touren'}',
    ];
    return parts.join(', ') +
        (skipped > 0 ? ' ($skipped schon vorhanden)' : '');
  }
}

class BackupService {
  static const String format = 'schraeglage-backup';
  static const int version = 1;

  static String fileName(DateTime d) =>
      'schraeglage-sicherung-${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}.json.gz';

  /// Schreibt die Sicherung nach [out].
  static Future<BackupResult> export(
      File out, RideStore rides, TourStore tours) async {
    final res = BackupResult();
    final sink = out.openWrite();
    final gz = gzip.encoder.startChunkedConversion(sink);
    void line(Map<String, dynamic> j) =>
        gz.add(utf8.encode('${jsonEncode(j)}\n'));
    try {
      line({
        'type': 'meta',
        'format': format,
        'version': version,
        'created': DateTime.now().toIso8601String(),
      });
      for (final s in await rides.listRides()) {
        final track = await rides.loadTrack(s.id);
        line({
          'type': 'ride',
          'summary': s.toJson(),
          'track': [for (final p in track) p.toJson()],
        });
        res.rides++;
      }
      for (final m in await tours.list()) {
        if (m.isLast) continue; // nur echte, gespeicherte Touren
        final plan = await tours.load(m.id);
        if (plan == null) continue;
        line({'type': 'tour', 'meta': m.toJson(), 'plan': planToJson(plan)});
        res.tours++;
      }
    } finally {
      // Schliesst auch die Datei (der Packer reicht das close() weiter).
      gz.close();
      await sink.done;
    }
    return res;
  }

  /// Spielt eine Sicherung ein. Vorhandenes bleibt, doppelte Eintraege
  /// werden uebersprungen.
  static Future<BackupResult> import(
      Stream<List<int>> input, RideStore rides, TourStore tours) async {
    final res = BackupResult();
    final haveRides = {for (final r in await rides.listRides()) r.id};
    final haveTours = {for (final t in await tours.list()) t.id};
    var first = true;
    await for (final raw in input
        .transform(gzip.decoder)
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (raw.trim().isEmpty) continue;
      final Object? j;
      try {
        j = jsonDecode(raw);
      } catch (_) {
        if (first) throw const FormatException('Keine Sicherung');
        res.skipped++;
        continue;
      }
      if (j is! Map<String, dynamic>) continue;
      if (first) {
        first = false;
        if (j['type'] != 'meta' || j['format'] != format) {
          throw const FormatException('Keine Schräglage-Sicherung');
        }
        continue;
      }
      switch (j['type']) {
        case 'ride':
          try {
            final s = RideSummary.fromJson(j['summary'] as Map<String, dynamic>);
            if (haveRides.contains(s.id)) {
              res.skipped++;
              break;
            }
            final track = [
              for (final p in (j['track'] as List? ?? const [])
                  .whereType<Map<String, dynamic>>())
                TrackPoint.fromJson(p),
            ];
            await rides.saveRide(s, track);
            haveRides.add(s.id);
            res.rides++;
          } catch (_) {
            res.skipped++;
          }
        case 'tour':
          final m = TourMeta.fromJson(j['meta']);
          final plan = planFromJson(j['plan']);
          if (m == null || plan == null || haveTours.contains(m.id)) {
            res.skipped++;
            break;
          }
          await tours.save(plan, title: m.title, id: m.id, savedAt: m.savedAt);
          haveTours.add(m.id);
          res.tours++;
      }
    }
    if (first) throw const FormatException('Leere Datei');
    return res;
  }
}

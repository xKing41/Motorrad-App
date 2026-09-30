import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:schraeglage/models/ride.dart';
import 'package:schraeglage/screens/legal_screen.dart';

void main() {
  test('Akku je Stunde: nur wenn aussagekraeftig', () {
    RideSummary r({int? a, int? b, bool chg = false, int dur = 7200}) =>
        RideSummary.fromJson(RideSummary(
          id: 'x',
          start: DateTime(2026, 5, 1),
          durationSec: dur,
          distanceM: 100000,
          maxLeanL: 0,
          maxLeanR: 0,
          maxSpeedMs: 0,
          maxBrakeG: 0,
          maxLatG: 0,
          pointCount: 0,
          batteryStart: a,
          batteryEnd: b,
          charged: chg,
        ).toJson());
    expect(r(a: 90, b: 70).batteryPerHour, 10);
    expect(r(a: 90, b: 70, chg: true).batteryPerHour, isNull);
    expect(r(a: 90, b: 89, dur: 300).batteryPerHour, isNull); // zu kurz
    expect(r().batteryPerHour, isNull);
    expect(r(a: 50, b: 60).batteryPerHour, isNull); // geladen, nicht gemerkt
  });

  test('Datenschutzerklaerung nennt jeden Dienst, den die App anspricht', () {
    final text = File('assets/legal/datenschutz.md').readAsStringSync();
    final hosts = <String>{};
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r"https://([a-z0-9.\-]+)").allMatches(src)) {
        hosts.add(m.group(1)!);
      }
      for (final m in RegExp(r"Uri\.https\('([a-z0-9.\-]+)'").allMatches(src)) {
        hosts.add(m.group(1)!);
      }
      for (final m in RegExp(r"'(broker\.[a-z.]+)'").allMatches(src)) {
        hosts.add(m.group(1)!);
      }
    }
    // Keine Datenuebertragung: nur Links, die der Nutzer selbst oeffnet,
    // Beispiel-Adressen und XML-Namensraeume.
    const ignore = {
      'www.openstreetmap.org', 'www.google.com', 'waze.com',
      'maps.apple.com', 'mein-server.de', 'schraeglage.app',
      'creativecommons.tankerkoenig.de', 'graphhopper.com',
      'api.anthropic.com', 'api.tomtom.com', 'data.traffic.hereapi.com',
    };
    final missing = [
      for (final h in hosts)
        if (!ignore.contains(h) && !text.contains(h)) h,
    ];
    expect(missing, isEmpty,
        reason: 'In assets/legal/datenschutz.md ergaenzen: $missing');
    // Die optionalen Dienste stehen zumindest mit Namen drin.
    for (final n in ['TomTom', 'HERE', 'Tankerkönig', 'KI', 'GraphHopper']) {
      expect(text, contains(n));
    }
  });

  test('Rechtstexte lassen sich darstellen', () {
    final w = LegalScreen.render('# Titel\n\n## Abschnitt\n- **fett** und normal\nText');
    expect(w.length, 5);
  });

  test('Datenschutz in App und Webseite ist gleich', () {
    final app = File('assets/legal/datenschutz.md').readAsStringSync();
    final web = File('../docs/datenschutz.md');
    if (!web.existsSync()) return; // Im CI-Projekt liegt docs/ nicht daneben.
    expect(web.readAsStringSync(), app,
        reason: 'docs/datenschutz.md und app/assets/legal/datenschutz.md '
            'gemeinsam pflegen');
  });
}

import 'package:flutter/material.dart';

import '../screens/pro_screen.dart';

// ---------------------------------------------------------------------------
//  PRO (Freemium)
//
//  Grundfunktionen bleiben fuer immer kostenlos - Sicherheit (Sturz-
//  erkennung, Notfall) sowieso. Pro gibt es fuer das, was laufend
//  Serverkosten verursacht. Solange [kProGating] aus ist, ist ALLES frei
//  (Testphase). Eingeschaltet wird erst, wenn eigene Server laufen und
//  der Kauf ueber Google Play eingebaut ist.
// ---------------------------------------------------------------------------

/// Bezahlschranke aktiv? In der Testphase: nein.
const bool kProGating = false;

enum ProFeature {
  groups('Gruppen mit Live-Position, Chat und Ausfahrten', Icons.groups),
  intercom('Live-Sprechfunk in der Gruppe', Icons.record_voice_over),
  aiIncluded('KI-Tourplanung ohne eigenen Schlüssel', Icons.auto_awesome),
  bigOffline('Große Offline-Gebiete, Neuberechnung ohne Netz',
      Icons.download_for_offline),
  radar('Regenradar und Verkehr auf allen Straßen', Icons.radar),
  cloudBackup('Sicherung in der Cloud', Icons.cloud_upload_outlined),
  serverSos('Automatischer Notruf über Server (auch ohne SMS-Recht)',
      Icons.sos);

  const ProFeature(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Was immer kostenlos bleibt (fuer die Uebersicht).
const freeFeatures = <(String, IconData)>[
  ('Touren planen, Varianten, Stopps', Icons.route),
  ('Navigation mit Ansagen', Icons.navigation),
  ('Prüfung auf Verbote und Feldwege', Icons.verified_outlined),
  ('Sturzerkennung und Notfall-SMS', Icons.emergency_outlined),
  ('Cockpit, Fahrten aufzeichnen und auswerten', Icons.speed),
  ('Eigene Sperrliste', Icons.block),
];

class Pro extends ChangeNotifier {
  Pro._();
  static final Pro instance = Pro._();

  /// Gekauft (spaeter aus Google Play). In der Testphase ohne Bedeutung.
  bool active = false;

  bool has(ProFeature f) => !kProGating || active;

  /// Vor einer Pro-Funktion aufrufen: true = darf. Sonst erklaert die
  /// App kurz, was Pro ist.
  Future<bool> gate(BuildContext context, ProFeature f) async {
    if (has(f)) return true;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => ProScreen(focus: f)));
    return has(f);
  }
}

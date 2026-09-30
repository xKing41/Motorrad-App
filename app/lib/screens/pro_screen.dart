import 'package:flutter/material.dart';

import '../services/pro.dart';
import '../theme.dart';

/// Kostenlos und Pro im Ueberblick. In der Testphase ist alles frei.
class ProScreen extends StatelessWidget {
  const ProScreen({super.key, this.focus});

  /// Funktion, wegen der die Seite geoeffnet wurde.
  final ProFeature? focus;

  @override
  Widget build(BuildContext context) {
    Widget row(IconData icon, String text, {Color color = chalk, bool hi = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(icon, size: 26, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: hi ? FontWeight.w800 : FontWeight.w500,
                      color: chalk)),
            ),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('SCHRÄGLAGE PRO')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: panel,
              border: Border.all(color: go, width: 1.5),
            ),
            child: const Text(
              'Testphase: Alle Funktionen sind kostenlos. Später bleibt die '
              'Grundausstattung frei - Pro gibt es für Funktionen, die '
              'eigene Server brauchen. Wer jetzt testet, bekommt Pro später '
              'günstiger.',
              style: TextStyle(fontSize: 16, color: chalk, height: 1.4),
            ),
          ),
          const SizedBox(height: 18),
          const TinyLabel('IMMER KOSTENLOS'),
          const SizedBox(height: 6),
          for (final (text, icon) in freeFeatures) row(icon, text, color: go),
          const SizedBox(height: 18),
          const TinyLabel('PRO', color: signal),
          const SizedBox(height: 6),
          for (final f in ProFeature.values)
            row(f.icon, f.label, color: signal, hi: f == focus),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme.dart';

/// Quellenangabe fuer die Kartendaten.
///
/// Die Karte stammt von OpenStreetMap. Deren Daten stehen unter der
/// Open Database License, und die verlangt, dass die Quelle genannt
/// wird - sichtbar dort, wo die Karte zu sehen ist. Ohne diesen Hinweis
/// duerfte die App nicht weitergegeben werden.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      color: asphalt.withValues(alpha: 0.65),
      child: const Text(
        '© OpenStreetMap-Mitwirkende',
        style: TextStyle(fontSize: 9, color: chalk),
      ),
    );
  }
}

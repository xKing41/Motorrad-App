import 'package:flutter/material.dart';

import '../services/vector_map.dart';
import '../theme.dart';

/// Quellenangabe fuer die Kartendaten.
///
/// Die Karte stammt von OpenStreetMap. Deren Daten stehen unter der
/// Open Database License, und die verlangt, dass die Quelle genannt
/// wird - sichtbar dort, wo die Karte zu sehen ist. Ohne diesen Hinweis
/// duerfte die App nicht weitergegeben werden. Bei der Vektorkarte
/// kommen OpenMapTiles (Schema/Stil) und OpenFreeMap (Server) dazu.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: VectorMap.instance,
      builder: (context, _) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        color: asphalt.withValues(alpha: 0.65),
        child: Text(
          VectorMap.instance.useVector
              ? VectorMap.attribution
              : '© OpenStreetMap-Mitwirkende',
          style: const TextStyle(fontSize: 9, color: chalk),
        ),
      ),
    );
  }
}

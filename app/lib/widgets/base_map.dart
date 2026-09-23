import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import '../services/offline_maps.dart';
import '../services/vector_map.dart';

/// Die Grundkarte: Vektorkarte (hell oder dunkel), wenn verfuegbar,
/// sonst die klassische OSM-Bildkarte.
///
/// Die Vektorkarte braucht einmal Netz, um die aktuelle Kachel-Adresse
/// von OpenFreeMap zu erfahren; bis dahin (erster Start ohne Netz)
/// kommt die klassische Karte.
Widget baseMapLayer({required bool night}) {
  final vm = VectorMap.instance;
  final theme = vm.theme(night: night);
  final providers = vm.tileProviders;
  if (vm.useVector && theme != null && providers != null) {
    return VectorTileLayer(
      // Neuer Schluessel bei Tag/Nacht-Wechsel: sauber neu zeichnen.
      key: ValueKey(night ? 'vec-night' : 'vec-day'),
      tileProviders: providers,
      theme: theme,
      // Gezeichnete Kacheln sind schneller als Live-Vektoren; beim
      // Fahren zaehlt fluessige Darstellung.
      layerMode: VectorTileLayerMode.raster,
      // Nur Daten bis 14 - darueber aus diesen Kacheln zeichnen.
      maximumZoom: 20,
      concurrency: 3,
    );
  }
  return TileLayer(
    urlTemplate: osmUrlTemplate,
    userAgentPackageName: 'de.schraeglage.app',
    maxNativeZoom: 19,
    // Kacheln vom Handy, im Funkloch auch vergroesserte groebere
    // Kacheln statt leerer Flaeche.
    tileProvider: OfflineMaps.tiles,
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/geocoder.dart';
import '../services/vector_map.dart';
import '../theme.dart';
import '../widgets/base_map.dart';
import '../widgets/map_attribution.dart';

/// Punkt auf der Karte waehlen - fuer Ziele, die keine Suche kennt
/// (Feldweg-Ende, Aussichtspunkt ohne Namen, Treffpunkt am Waldrand).
/// Die Karte unter dem Fadenkreuz verschieben, dann "HIER".
class MapPickScreen extends StatefulWidget {
  const MapPickScreen({super.key, this.lat, this.lon, this.title = 'PUNKT WÄHLEN'});

  final double? lat;
  final double? lon;
  final String title;

  @override
  State<MapPickScreen> createState() => _MapPickScreenState();
}

class _MapPickScreenState extends State<MapPickScreen> {
  final _map = MapController();
  bool _busy = false;

  Future<void> _pick() async {
    final c = _map.camera.center;
    setState(() => _busy = true);
    final named = await Geocoder.reverse(c.latitude, c.longitude);
    if (!mounted) return;
    Navigator.pop(
      context,
      named ??
          Place(
            name: 'Punkt ${c.latitude.toStringAsFixed(5)}, '
                '${c.longitude.toStringAsFixed(5)}',
            kind: 'Punkt auf der Karte',
            lat: c.latitude,
            lon: c.longitude,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final center = widget.lat != null
        ? LatLng(widget.lat!, widget.lon!)
        : const LatLng(51.1657, 10.4515);
    final night = VectorMap.instance.nightAt(DateTime.now(), widget.lat, widget.lon);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: center,
            initialZoom: widget.lat != null ? 14 : 6,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [baseMapLayer(night: night)],
        ),
        // Fadenkreuz: die Nadelspitze zeigt auf die Kartenmitte.
        const IgnorePointer(
          child: Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: 40),
              child: Icon(Icons.location_on, size: 44, color: signal),
            ),
          ),
        ),
        const Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.only(left: 4, bottom: 84),
            child: MapAttribution(),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 16,
          child: SafeArea(
            child: FlatButton2(
              label: _busy ? 'NAME WIRD GESUCHT ...' : 'HIER',
              color: signal,
              fill: signal,
              strong: true,
              tall: true,
              onTap: _busy ? null : _pick,
            ),
          ),
        ),
      ]),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/ride.dart';
import '../services/gpx_service.dart';
import '../services/ride_store.dart';
import '../theme.dart';
import '../widgets/map_attribution.dart';
import 'ride_analysis_screen.dart';

/// Eine gefahrene Tour im Detail: Karte mit nach Schraeglage
/// eingefaerbter Strecke, Kurvenauswertung und Export.
class RideDetailScreen extends StatefulWidget {
  const RideDetailScreen({super.key, required this.ride});

  final RideSummary ride;

  @override
  State<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends State<RideDetailScreen> {
  final _map = MapController();
  List<TrackPoint> _track = [];
  List<Corner> _corners = [];
  bool _loaded = false;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final track = await RideStore.instance.loadTrack(widget.ride.id);
    if (!mounted) return;
    setState(() {
      _track = track;
      _corners = detectCorners(track);
      _loaded = true;
    });
    _fit();
  }

  void _fit() {
    if (!_mapReady || _track.isEmpty) return;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in _track) {
      minLat = p.lat < minLat ? p.lat : minLat;
      maxLat = p.lat > maxLat ? p.lat : maxLat;
      minLon = p.lon < minLon ? p.lon : minLon;
      maxLon = p.lon > maxLon ? p.lon : maxLon;
    }
    if (minLat > maxLat) return;
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon)),
      padding: const EdgeInsets.all(30),
    ));
  }

  Future<void> _export() async {
    final msg = await GpxService.share(
      'fahrt_${widget.ride.id}.gpx',
      GpxService.trackToGpx(widget.ride, _track),
      subject: 'Fahrt ${fmtDate(widget.ride.start)}',
    );
    if (msg != null && mounted) toast(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.ride;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FAHRT'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share, size: 18, color: steel),
            onPressed: _loaded && _track.isNotEmpty ? _export : null,
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator(color: signal))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                Text(fmtDate(r.start),
                    style: const TextStyle(
                        fontSize: 11, letterSpacing: 1.5, color: steel)),
                const SizedBox(height: 10),
                if (_track.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: panel, border: Border.all(color: line)),
                    child: const Text(
                      'Für diese Fahrt wurde keine Strecke aufgezeichnet '
                      '(vermutlich ohne GPS gestartet).',
                      style: TextStyle(fontSize: 11.5, color: steel),
                    ),
                  )
                else
                  _mapBox(),
                const SizedBox(height: 12),
                _statsGrid(r),
                const SizedBox(height: 12),
                // Zugang zur Tiefenauswertung: Fahrstil, Histogramm,
                // Kammscher Kreis.
                SizedBox(
                  width: double.infinity,
                  child: FlatButton2(
                    label: 'FAHRSTIL AUSWERTEN',
                    color: cool,
                    strong: true,
                    onTap: _track.length < 5
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => RideAnalysisScreen(
                                  ride: r,
                                  track: _track,
                                ),
                              ),
                            ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_corners.isNotEmpty) ...[
                  const TinyLabel('KURVEN'),
                  const SizedBox(height: 8),
                  _cornerSummary(),
                  const SizedBox(height: 10),
                  ..._corners
                      .where((c) => c.maxLean >= 18)
                      .take(20)
                      .map(_cornerTile),
                ],
              ],
            ),
    );
  }

  Widget _mapBox() {
    return Column(children: [
      SizedBox(
        height: 280,
        child: ClipRect(
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: LatLng(_track.first.lat, _track.first.lon),
              initialZoom: 12,
              onMapReady: () {
                _mapReady = true;
                _fit();
              },
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'de.schraeglage.app',
                maxNativeZoom: 19,
              ),
              PolylineLayer(polylines: _coloredTrack()),
              MarkerLayer(markers: [
                Marker(
                  point: LatLng(_track.first.lat, _track.first.lon),
                  width: 16,
                  height: 16,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF7FBF4F),
                      shape: BoxShape.circle,
                      border: Border.all(color: chalk, width: 2),
                    ),
                  ),
                ),
                Marker(
                  point: LatLng(_track.last.lat, _track.last.lon),
                  width: 16,
                  height: 16,
                  child: Container(
                    decoration: BoxDecoration(
                      color: redline,
                      shape: BoxShape.circle,
                      border: Border.all(color: chalk, width: 2),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
      const Align(
        alignment: Alignment.centerRight,
        child: MapAttribution(),
      ),
      const SizedBox(height: 6),
      _legend(),
    ]);
  }

  Widget _legend() {
    Widget dot(Color c, String s) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 9, height: 4, color: c),
          const SizedBox(width: 4),
          Text(s, style: const TextStyle(fontSize: 8.5, color: steel)),
        ]);

    return Wrap(
      spacing: 12,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        dot(leanColor(0), '0–8°'),
        dot(leanColor(10), '8–20°'),
        dot(leanColor(25), '20–35°'),
        dot(leanColor(40), '35–48°'),
        dot(leanColor(50), 'ab 48°'),
      ],
    );
  }

  /// Strecke in Segmente zerlegt und nach Schraeglage eingefaerbt.
  List<Polyline> _coloredTrack() {
    if (_track.length < 2) return const [];
    final out = <Polyline>[];
    var segStart = 0;
    var currentColor = leanColor(_track.first.lean.abs());

    for (var i = 1; i < _track.length; i++) {
      final c = leanColor(_track[i].lean.abs());
      final last = i == _track.length - 1;
      if (c != currentColor || last) {
        final end = last ? i : i - 1;
        if (end > segStart) {
          out.add(Polyline(
            points: _track
                .sublist(segStart, end + 1)
                .map((p) => LatLng(p.lat, p.lon))
                .toList(),
            color: currentColor,
            strokeWidth: 4.5,
          ));
        }
        segStart = end;
        currentColor = c;
      }
    }
    return out;
  }

  Widget _statsGrid(RideSummary r) {
    return Column(children: [
      Row(children: [
        Expanded(
            child: StatCard(
                label: 'STRECKE',
                value: r.distanceKm.toStringAsFixed(1),
                unit: ' km')),
        const SizedBox(width: 8),
        Expanded(
            child: StatCard(
                label: 'DAUER', value: fmtDur(r.durationSec))),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
            child: StatCard(
                label: r.movingSec != null ? 'Ø IN FAHRT' : 'Ø TEMPO',
                value: '${r.avgSpeedKmh.round()}',
                unit: ' km/h')),
        const SizedBox(width: 8),
        Expanded(
            child: StatCard(
                label: 'VMAX',
                value: '${r.maxSpeedKmh.round()}',
                unit: ' km/h')),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
            child: StatCard(
                label: 'MAX LINKS',
                value: '${r.maxLeanL.round()}',
                unit: '°')),
        const SizedBox(width: 8),
        Expanded(
            child: StatCard(
                label: 'MAX RECHTS',
                value: '${r.maxLeanR.round()}',
                unit: '°')),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
            child: StatCard(
                label: 'BREMS-G', value: r.maxBrakeG.toStringAsFixed(2))),
        const SizedBox(width: 8),
        Expanded(
            child: StatCard(
                label: 'KURVEN-G', value: r.maxLatG.toStringAsFixed(2))),
      ]),
    ]);
  }

  Widget _cornerSummary() {
    final left = _corners.where((c) => c.direction < 0).toList();
    final right = _corners.where((c) => c.direction > 0).toList();
    double avg(List<Corner> l) =>
        l.isEmpty ? 0 : l.map((c) => c.maxLean).reduce((a, b) => a + b) / l.length;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: panel, border: Border.all(color: line)),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Column(children: [
              const TinyLabel('LINKSKURVEN'),
              const SizedBox(height: 3),
              Text('${left.length}',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, color: chalk)),
              Text('Ø ${avg(left).round()}°',
                  style: const TextStyle(fontSize: 10, color: steel)),
            ]),
          ),
          Container(width: 1, height: 42, color: line),
          Expanded(
            child: Column(children: [
              const TinyLabel('RECHTSKURVEN'),
              const SizedBox(height: 3),
              Text('${right.length}',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, color: chalk)),
              Text('Ø ${avg(right).round()}°',
                  style: const TextStyle(fontSize: 10, color: steel)),
            ]),
          ),
        ]),
        if (left.isNotEmpty && right.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            (avg(left) - avg(right)).abs() < 3
                ? 'Links und rechts liegst du gleichmäßig.'
                : avg(left) > avg(right)
                    ? 'Linkskurven liegen dir im Schnitt besser.'
                    : 'Rechtskurven liegen dir im Schnitt besser.',
            style: const TextStyle(fontSize: 10.5, color: cool),
          ),
        ],
      ]),
    );
  }

  Widget _cornerTile(Corner c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: panel,
          border: Border(
            left: BorderSide(color: leanColor(c.maxLean), width: 3),
            top: const BorderSide(color: line),
            right: const BorderSide(color: line),
            bottom: const BorderSide(color: line),
          ),
        ),
        child: Row(children: [
          Icon(c.direction < 0 ? Icons.turn_left : Icons.turn_right,
              size: 16, color: steel),
          const SizedBox(width: 10),
          Text('${c.maxLean.round()}°',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: leanColor(c.maxLean),
              )),
          const Spacer(),
          Text(
            'rein ${c.entrySpeedKmh.round()} · '
            'min ${c.minSpeedKmh.round()} · '
            'raus ${c.exitSpeedKmh.round()} km/h',
            style: const TextStyle(fontSize: 9.5, color: steel),
          ),
        ]),
      ),
    );
  }
}

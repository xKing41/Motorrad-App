import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_plan.dart';
import '../services/gpx_service.dart';
import '../services/poi_service.dart';
import '../services/route_follow.dart';
import '../services/telemetry.dart';
import '../theme.dart';
import '../widgets/map_attribution.dart';
import 'route_planner_screen.dart';

/// Karte mit Live-Position, aufgezeichneter Spur, geladener Route
/// und Zwischenstopps.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.onToggleRide});

  final VoidCallback onToggleRide;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final t = Telemetry.instance;
  final _map = MapController();

  RoutePlan? _route;
  // Die Route als fertige Kartenpunkte. Vorher wurde die Liste bei jedem
  // Neuaufbau (5-mal je Sekunde) komplett neu erzeugt - bei langen
  // Routen zehntausende Objekte pro Sekunde.
  List<LatLng> _routeLine = const [];
  // Vorschlaege des Planers zum Durchblaettern.
  List<RoutePlan> _variants = const [];
  int _variantIdx = 0;
  RouteFollower? _follower;
  FollowState? _follow;
  List<Poi> _pois = [];
  bool _autoFollow = true;
  bool _busy = false;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    t.addListener(_onTick);
  }

  @override
  void dispose() {
    t.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (!mounted) return;
    if (_follower != null && t.lat != null) {
      _follow = _follower!.update(t.lat!, t.lon!);
    }
    if (_autoFollow && _mapReady && t.lat != null) {
      _map.move(LatLng(t.lat!, t.lon!), _map.camera.zoom);
    }
    setState(() {});
  }

  // ------------------------------------------------------------------
  // Aktionen
  // ------------------------------------------------------------------
  /// GPX uebernehmen, ohne zusaetzliches Paket: Der Fahrer oeffnet die
  /// .gpx-Datei irgendwo (Dateimanager, Mail, Messenger), kopiert den
  /// Inhalt und fuegt ihn hier ein.
  Future<void> _importGpx() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: line),
        ),
        title: const Text(
          'GPX EINFÜGEN',
          style: TextStyle(fontSize: 12, letterSpacing: 2.5, color: chalk),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'GPX-Datei öffnen, kompletten Inhalt kopieren und hier '
              'einfügen. Erkannt werden Track-, Routen- und Wegpunkte.',
              style: TextStyle(fontSize: 11, color: steel, height: 1.4),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              maxLines: 6,
              style: const TextStyle(fontSize: 10, color: chalk),
              decoration: const InputDecoration(
                hintText: '<gpx ...> ... </gpx>',
                hintStyle: TextStyle(fontSize: 10, color: steel),
                filled: true,
                fillColor: asphalt,
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: line),
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ABBRECHEN',
                style: TextStyle(fontSize: 11, color: steel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('LADEN',
                style: TextStyle(fontSize: 11, color: signal)),
          ),
        ],
      ),
    );

    if (ok != true) return;
    final xml = ctrl.text.trim();
    if (xml.isEmpty) return;

    final plan = GpxService.parseRoute(xml);
    if (plan.isEmpty) {
      if (mounted) toast(context, 'Keine Punkte gefunden');
      return;
    }
    _setRoute(plan);
    if (mounted) {
      toast(context, 'Route geladen: ${plan.distanceKm.toStringAsFixed(1)} km');
    }
  }

  void _setRoute(RoutePlan plan, {bool keepVariants = false}) {
    setState(() {
      if (!keepVariants) {
        _variants = [plan, ...plan.alternatives];
        _variantIdx = 0;
      }
      _route = plan;
      _routeLine = plan.points
          .map((p) => LatLng(p.lat, p.lon))
          .toList(growable: false);
      _follower = RouteFollower(plan);
      _follow = null;
      _pois = plan.pois;
      _autoFollow = false;
    });
    _fitRoute(plan);
  }

  void _nextVariant() {
    if (_variants.length < 2) return;
    _variantIdx = (_variantIdx + 1) % _variants.length;
    _setRoute(_variants[_variantIdx], keepVariants: true);
  }

  void _clearRoute() {
    setState(() {
      _route = null;
      _routeLine = const [];
      _variants = const [];
      _variantIdx = 0;
      _follower = null;
      _follow = null;
      // Stopps und GPX-Wegpunkte gehoeren zur Route und gehen mit ihr.
      _pois = _pois.where((p) => p.source == 'osm').toList();
    });
  }

  void _fitRoute(RoutePlan plan) {
    if (!_mapReady || plan.points.isEmpty) return;
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final p in plan.points) {
      minLat = p.lat < minLat ? p.lat : minLat;
      maxLat = p.lat > maxLat ? p.lat : maxLat;
      minLon = p.lon < minLon ? p.lon : minLon;
      maxLon = p.lon > maxLon ? p.lon : maxLon;
    }
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon)),
      padding: const EdgeInsets.all(40),
    ));
  }

  Future<void> _loadPois() async {
    if (t.lat == null) {
      toast(context, 'Warte auf GPS-Position');
      return;
    }
    setState(() => _busy = true);
    final list = await PoiService.search(
      lat: t.lat!,
      lon: t.lon!,
      kinds: [PoiKind.fuel, PoiKind.viewpoint, PoiKind.rest, PoiKind.food],
      radiusM: 12000,
      limitPerKind: 12,
    );
    if (!mounted) return;
    setState(() {
      _pois = [..._pois.where((p) => p.source != 'osm'), ...list];
      _busy = false;
    });
    toast(context,
        list.isEmpty ? 'Nichts gefunden (Internet?)' : '${list.length} Orte geladen');
  }

  Future<void> _openPlanner() async {
    final plan = await Navigator.push<RoutePlan>(
      context,
      MaterialPageRoute(
        builder: (_) => RoutePlannerScreen(
          startLat: t.lat,
          startLon: t.lon,
        ),
      ),
    );
    if (plan == null || plan.isEmpty || !mounted) return;
    _setRoute(plan);
    // Beschreibung der KI und Hinweise des Planers (z. B. "keine
    // Tankstelle gefunden") gleich zeigen - vorher wurden sie berechnet
    // und nirgends angezeigt.
    if (plan.description != null || plan.notes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showRouteInfo();
      });
    }
  }

  Future<void> _exportRoute() async {
    final r = _route;
    if (r == null) return;
    final msg = await GpxService.share(
      '${(r.title ?? 'route')}.gpx',
      GpxService.routeToGpx(r),
      subject: r.title,
    );
    if (msg != null && mounted) toast(context, msg);
  }

  // ------------------------------------------------------------------
  // Aufbau
  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final center = t.lat != null
        ? LatLng(t.lat!, t.lon!)
        : const LatLng(51.1657, 10.4515); // Mitte Deutschland als Rueckfall

    return SafeArea(
      child: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 13,
            onMapReady: () {
              _mapReady = true;
              if (_route != null) _fitRoute(_route!);
            },
            onPositionChanged: (pos, hasGesture) {
              if (hasGesture && _autoFollow) {
                setState(() => _autoFollow = false);
              }
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
            if (_routeLine.length >= 2)
              PolylineLayer(polylines: [
                Polyline(
                  points: _routeLine,
                  color: cool.withValues(alpha: 0.85),
                  strokeWidth: 5,
                ),
              ]),
            PolylineLayer(polylines: _liveTrackPolylines()),
            MarkerLayer(markers: _markers()),
            // Pflichtangabe zur Kartenquelle. Liegt oberhalb des
            // Tastenbands, damit sie nicht verdeckt wird.
            const Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 4, bottom: 104),
                child: MapAttribution(),
              ),
            ),
          ],
        ),

        // Kopfzeile mit Route-Info
        Positioned(top: 8, left: 12, right: 12, child: _topBar()),

        // Bedienleiste unten
        Positioned(left: 12, right: 12, bottom: 10, child: _bottomBar()),

        if (_busy)
          const Positioned(
            top: 70,
            left: 0,
            right: 0,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(color: signal, strokeWidth: 2),
              ),
            ),
          ),
      ]),
    );
  }

  /// Live aufgezeichnete Spur, eingefaerbt nach Schraeglage.
  /// Aufeinanderfolgende Punkte mit aehnlicher Schraeglage werden zu
  /// einem Segment zusammengefasst, damit nicht tausende Linien entstehen.
  // -----------------------------------------------------------------
  // Farbige Live-Spur
  //
  // Vorher wurde bei JEDEM Neuaufbau der Karte die komplette Strecke
  // durchgerechnet und fuer jeden Punkt ein neues LatLng erzeugt.
  // Bei einem Punkt alle 700 ms sind das nach vier Stunden Fahrt rund
  // 20.000 Punkte - und das mehrfach je Sekunde. Genau das laesst die
  // Karte gegen Ende einer langen Tour zaeh werden.
  //
  // Jetzt werden nur die tatsaechlich neu hinzugekommenen Punkte
  // angehaengt. Fertige Abschnitte bleiben unveraendert liegen.
  // -----------------------------------------------------------------
  final List<Polyline> _doneSegs = [];
  List<LatLng> _openPts = [];
  Color? _openColor;
  int _builtUpTo = 0;
  List<Polyline>? _polyCache;

  List<Polyline> _liveTrackPolylines() {
    final track = t.track;

    // Aufzeichnung wurde zurueckgesetzt: Zwischenspeicher leeren.
    if (track.length < _builtUpTo) {
      _doneSegs.clear();
      _openPts = [];
      _openColor = null;
      _builtUpTo = 0;
      _polyCache = null;
    }

    // Kein neuer Punkt? Dann das fertige Ergebnis wiederverwenden.
    if (track.length == _builtUpTo && _polyCache != null) return _polyCache!;

    for (var i = _builtUpTo; i < track.length; i++) {
      final p = track[i];
      final c = leanColor(p.lean.abs());
      final ll = LatLng(p.lat, p.lon);
      if (_openColor == null) {
        _openColor = c;
        _openPts = [ll];
      } else if (c != _openColor) {
        // Farbwechsel: Der Punkt gehoert an beide Abschnitte, sonst
        // klafft in der Linie eine Luecke.
        _openPts.add(ll);
        _doneSegs.add(Polyline(
          points: _openPts,
          color: _openColor!,
          strokeWidth: 4,
        ));
        _openColor = c;
        _openPts = [ll];
      } else {
        _openPts.add(ll);
      }
    }
    _builtUpTo = track.length;

    // Der offene Abschnitt waechst noch, deshalb hier eine eigene Kopie:
    // sonst wuerde sich die bereits uebergebene Linie nachtraeglich
    // veraendern. Die fertigen Abschnitte brauchen keine Kopie.
    _polyCache = _openPts.length < 2
        ? List<Polyline>.of(_doneSegs)
        : <Polyline>[
            ..._doneSegs,
            Polyline(
              points: List<LatLng>.of(_openPts),
              color: _openColor!,
              strokeWidth: 4,
            ),
          ];
    return _polyCache!;
  }

  List<Marker> _markers() {
    final out = <Marker>[];

    // Start und Ziel der Route. Bei einer Rundtour liegen beide an
    // derselben Stelle - dann genuegt eine Zielflagge.
    if (_routeLine.length >= 2) {
      final a = _routeLine.first, b = _routeLine.last;
      final loop = const Distance().as(LengthUnit.Meter, a, b) < 150;
      if (!loop) out.add(_flag(a, const Color(0xFF7FBF4F), Icons.trip_origin));
      out.add(_flag(b, loop ? const Color(0xFF7FBF4F) : redline, Icons.flag));
    }

    for (final p in _pois) {
      final info = {
        p.kind.label,
        p.displayName,
        if (p.detail != null && p.detail != p.displayName) p.detail!,
        if (p.note != null) p.note!,
      }.join(' · ');
      out.add(Marker(
        point: LatLng(p.lat, p.lon),
        width: 30,
        height: 30,
        child: GestureDetector(
          onTap: () => toast(context, info),
          child: Container(
            decoration: BoxDecoration(
              color: panel,
              shape: BoxShape.circle,
              border: Border.all(color: _poiColor(p.kind), width: 2),
            ),
            child: Icon(p.source == 'gpx' ? Icons.push_pin : _poiIcon(p.kind),
                size: 15, color: _poiColor(p.kind)),
          ),
        ),
      ));
    }

    if (t.lat != null) {
      out.add(Marker(
        point: LatLng(t.lat!, t.lon!),
        width: 26,
        height: 26,
        child: Container(
          decoration: BoxDecoration(
            color: signal,
            shape: BoxShape.circle,
            border: Border.all(color: chalk, width: 2.5),
          ),
        ),
      ));
    }
    return out;
  }

  Marker _flag(LatLng at, Color c, IconData icon) => Marker(
        point: at,
        width: 24,
        height: 24,
        child: Container(
          decoration: BoxDecoration(
            color: panel,
            shape: BoxShape.circle,
            border: Border.all(color: c, width: 2),
          ),
          child: Icon(icon, size: 13, color: c),
        ),
      );

  IconData _poiIcon(PoiKind k) => switch (k) {
        PoiKind.fuel => Icons.local_gas_station,
        PoiKind.viewpoint => Icons.photo_camera,
        PoiKind.food => Icons.restaurant,
        PoiKind.rest => Icons.park,
        PoiKind.water => Icons.water_drop,
        PoiKind.workshop => Icons.build,
      };

  Color _poiColor(PoiKind k) => switch (k) {
        PoiKind.fuel => amber,
        PoiKind.viewpoint => cool,
        PoiKind.food => const Color(0xFF7FBF4F),
        _ => steel,
      };

  static String _fmtKm(double m) =>
      '${(m / 1000).toStringAsFixed(m >= 100000 ? 0 : 1).replaceAll('.', ',')} km';

  static String _fmtDuration(int sec) {
    final h = sec ~/ 3600;
    final m = ((sec % 3600) / 60).round();
    if (h == 0) return '$m min';
    return '$h h ${m.toString().padLeft(2, '0')} min';
  }

  Widget _topBar() {
    final r = _route;
    final f = _follow;

    String sub;
    if (r == null) {
      sub = 'GPX laden oder Route planen';
    } else if (f == null) {
      sub = [
        _fmtKm(r.distanceM),
        if (r.durationSec > 0) 'ca. ${_fmtDuration(r.durationSec)}',
        if (r.stats != null) 'Kurven ${r.stats!.curvLabel}',
      ].join(' · ');
    } else if (f.isOffRoute) {
      sub = 'ABSEITS DER ROUTE · ${f.offRouteM >= 1000 ? _fmtKm(f.offRouteM) : '${f.offRouteM.round()} m'}';
    } else {
      sub = 'NOCH ${_fmtKm(f.remainingM)} · ${(f.progress * 100).round()} %';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: panel.withValues(alpha: 0.94),
        border: Border.all(color: f?.isOffRoute == true ? amber : line),
      ),
      child: Row(children: [
        Expanded(
          child: InkWell(
            onTap: r == null ? null : _showRouteInfo,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r?.title ?? 'KEINE ROUTE GELADEN',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, letterSpacing: 1.5, color: chalk),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      letterSpacing: 1.2,
                      color: f?.isOffRoute == true ? amber : steel,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_variants.length > 1)
          InkWell(
            onTap: _nextVariant,
            child: Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(border: Border.all(color: cool)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('VARIANTE',
                    style: TextStyle(
                        fontSize: 7.5, letterSpacing: 1.2, color: cool)),
                Text('${_variantIdx + 1}/${_variants.length} ›',
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, color: cool)),
              ]),
            ),
          ),
        if (r != null)
          IconButton(
            tooltip: 'Details',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.info_outline, size: 17, color: steel),
            onPressed: _showRouteInfo,
          ),
        if (r != null)
          IconButton(
            tooltip: 'Route entfernen',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16, color: steel),
            onPressed: _clearRoute,
          ),
      ]),
    );
  }

  /// Alles, was der Planer ueber die Route weiss - auch WARUM er genau
  /// diese Variante vorschlaegt.
  void _showRouteInfo() {
    final r = _route;
    if (r == null) return;
    final st = r.stats;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(
                child: Text(k,
                    style: const TextStyle(fontSize: 11, color: steel))),
            Text(v, style: const TextStyle(fontSize: 11.5, color: chalk)),
          ]),
        );

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            children: [
              Text((r.title ?? 'ROUTE').toUpperCase(),
                  style: const TextStyle(
                      fontSize: 12, letterSpacing: 2, color: chalk)),
              if (_variants.length > 1)
                Text('Variante ${_variantIdx + 1} von ${_variants.length}',
                    style: const TextStyle(fontSize: 10, color: cool)),
              const SizedBox(height: 10),
              row('Länge', _fmtKm(r.distanceM)),
              if (r.durationSec > 0)
                row('Fahrzeit (Schätzung)', _fmtDuration(r.durationSec)),
              if (st != null) ...[
                row('Kurvigkeit', st.curvLabel),
                row('Kurven je km',
                    st.bendsPerKm.toStringAsFixed(1).replaceAll('.', ',')),
                row('Doppelt gefahren', '${(st.overlapShare * 100).round()} %'),
                if (st.knownShare > 0)
                  row('Eigene bekannte Strecken',
                      '${(st.knownShare * 100).round()} %'),
              ],
              if (r.engineLabel != null) row('Berechnet mit', r.engineLabel!),
              if (r.pois.isNotEmpty) ...[
                const SizedBox(height: 10),
                const TinyLabel('STOPPS'),
                const SizedBox(height: 4),
                for (final p in r.pois)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Icon(_poiIcon(p.kind), size: 14, color: _poiColor(p.kind)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          [
                            p.displayName,
                            if (p.detail != null && p.detail != p.displayName)
                              p.detail!,
                          ]
                              .join(' · '),
                          style: const TextStyle(fontSize: 11, color: chalk),
                        ),
                      ),
                    ]),
                  ),
              ],
              if (r.description != null) ...[
                const SizedBox(height: 10),
                Text(r.description!,
                    style: const TextStyle(
                        fontSize: 11.5, color: cool, height: 1.45)),
              ],
              for (final n in r.notes)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(n,
                      style: const TextStyle(fontSize: 10.5, color: amber)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Column(children: [
      Row(children: [
        Expanded(
          child: _mapBtn(
            icon: Icons.route,
            label: 'PLANEN',
            onTap: _openPlanner,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _mapBtn(
            icon: Icons.folder_open,
            label: 'GPX',
            onTap: _importGpx,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _mapBtn(
            icon: Icons.place,
            label: 'ORTE',
            onTap: _loadPois,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _mapBtn(
            icon: _autoFollow ? Icons.my_location : Icons.location_searching,
            label: 'FOLGEN',
            active: _autoFollow,
            onTap: () {
              setState(() => _autoFollow = !_autoFollow);
              if (_autoFollow && t.lat != null && _mapReady) {
                _map.move(LatLng(t.lat!, t.lon!), 15);
              }
            },
          ),
        ),
        if (_route != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: _mapBtn(
              icon: Icons.ios_share,
              label: 'EXPORT',
              onTap: _exportRoute,
            ),
          ),
        ],
      ]),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: FlatButton2(
          label: t.recording ? 'FAHRT BEENDEN' : 'FAHRT STARTEN',
          color: t.recording ? amber : signal,
          strong: true,
          onTap: widget.onToggleRide,
        ),
      ),
    ]);
  }

  Widget _mapBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    final c = active ? signal : chalk;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: panel.withValues(alpha: 0.94),
          border: Border.all(color: active ? signal : line),
        ),
        child: Column(children: [
          Icon(icon, size: 17, color: c),
          const SizedBox(height: 3),
          Text(label,
              style: TextStyle(fontSize: 8, letterSpacing: 1.2, color: c)),
        ]),
      ),
    );
  }
}

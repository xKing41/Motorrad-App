import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/route_plan.dart';
import '../services/external_nav.dart';
import '../services/gpx_service.dart';
import '../services/navigation.dart';
import '../services/offline_maps.dart';
import '../services/poi_service.dart';
import '../services/route_follow.dart';
import '../services/smooth_position.dart';
import '../services/routing_engine.dart';
import '../services/routing_settings.dart';
import '../services/telemetry.dart';
import '../services/tile_cache.dart';
import '../services/voice.dart';
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

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
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

  /// Laufende Navigation (null = nur Route anzeigen).
  NavigationSession? _nav;

  // Fluessige Anzeige: zwischen den GPS-Messungen (1 je Sekunde) wird mit
  // rund 30 Bildern je Sekunde weitergerechnet.
  final SmoothTracker _tracker = SmoothTracker();
  late final Ticker _ticker;
  int _lastSeq = -1;
  int _lastFrameUs = 0;
  double _zoom = 16;

  // Verkehrsfluss als farbige Schicht (TomTom): gruen = frei, gelb/rot =
  // zaeh bis Stau.
  String _tomtomKey = '';
  bool _showFlow = true;

  // Kartenkacheln mit Speicher auf dem Handy (Offline-Karten).
  final _offline = OfflineMaps.instance;

  /// Position und Richtung des eigenen Pfeils.
  final ValueNotifier<(LatLng, double)?> _rider = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onFrame);
    t.addListener(_onTick);
    _offline.addListener(_onOffline);
    _offline.offline.addListener(_onOffline);
    _loadTrafficKey();
    _offline.cache();
  }

  void _onOffline() {
    if (mounted) setState(() {});
  }

  Future<void> _loadTrafficKey() async {
    final s = await RoutingSettings.load();
    if (mounted) setState(() => _tomtomKey = s.tomtomKey.trim());
  }

  @override
  void dispose() {
    t.removeListener(_onTick);
    _offline.removeListener(_onOffline);
    _offline.offline.removeListener(_onOffline);
    _ticker.dispose();
    _rider.dispose();
    _nav?.dispose();
    super.dispose();
  }

  bool get _smooth => t.foreground && (_nav != null || t.recording);

  void _onFrame(Duration _) {
    final now = DateTime.now().microsecondsSinceEpoch;
    // 30 Bilder je Sekunde reichen fuer eine fluessige Karte und sparen
    // gegenueber 60 die Haelfte an Rechenzeit.
    if (now - _lastFrameUs < 33000) return;
    _lastFrameUs = now;
    final nav = _nav;
    _tracker.frame(now,
        route: nav?.plan.points, cum: nav?.routeCum);
    final p = _tracker.pos;
    if (p == null) return;
    final ll = LatLng(p.lat, p.lon);
    _rider.value = (ll, _tracker.heading);
    if (!_autoFollow || !_mapReady) return;
    if (nav != null) {
      _followCourseUp(ll, _tracker.heading);
    } else {
      _map.move(ll, _map.camera.zoom);
    }
  }

  void _onTick() {
    if (!mounted) return;
    final nav = _nav;
    if (nav != null && t.lat != null) {
      // Laeuft auch im Hintergrund weiter: Ansagen, Neuberechnung.
      nav.update(t.lat!, t.lon!, heading: t.headingDeg, speedMs: t.speedMs);
    } else if (_follower != null && t.lat != null) {
      _follow = _follower!.update(t.lat!, t.lon!);
    }
    // Neue GPS-Messung an die fluessige Anzeige geben.
    if (t.lat != null && t.fixSeq != _lastSeq) {
      _lastSeq = t.fixSeq;
      _tracker.onFix(RoutePoint(t.lat!, t.lon!), t.speedMs, t.headingDeg,
          DateTime.now().microsecondsSinceEpoch,
          alongM: (nav != null && nav.onRoute) ? nav.alongM : null);
    }
    // Karte bewegen und neu zeichnen nur, wenn sie jemand sieht.
    if (!t.foreground) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (_smooth) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) _ticker.stop();
      if (t.lat != null) {
        final ll = LatLng(t.lat!, t.lon!);
        _rider.value = (ll, t.headingDeg ?? 0);
        if (_autoFollow && _mapReady) _map.move(ll, _map.camera.zoom);
      }
    }
    setState(() {});
  }

  /// Karte in Fahrtrichtung drehen, Position im unteren Drittel - so
  /// sieht man, was kommt, wie bei jedem Navi. Der Zoom passt sich weich
  /// dem Tempo an.
  void _followCourseUp(LatLng at, double heading) {
    final target = SmoothTracker.zoomForSpeed(t.speedMs);
    _zoom += (target - _zoom) * 0.03;
    final mpp =
        156543.03 * math.cos(at.latitude * math.pi / 180) / math.pow(2, _zoom);
    final ahead = mpp * MediaQuery.of(context).size.height * 0.22;
    final c = const Distance().offset(at, ahead, heading);
    _map.moveAndRotate(c, _zoom, -heading);
  }

  // ------------------------------------------------------------------
  // Navigation
  // ------------------------------------------------------------------
  Future<void> _startNav() async {
    final r = _route;
    if (r == null) return;
    final settings = await RoutingSettings.load();
    Voice.instance.enabled = settings.voice;
    final nav = NavigationSession(
      plan: r,
      engine: settings.engine(),
      prefs: r.request != null
          ? RoutingPrefs.of(r.request!)
          : const RoutingPrefs(),
      traffic: settings.trafficFeed(),
      speak: settings.voice ? (s) => Voice.instance.say(s) : null,
    );
    nav.addListener(_onNavChanged);
    if (!mounted) return;
    await t.setNavigating(true);
    setState(() {
      _nav = nav;
      _autoFollow = true;
    });
    _zoom = SmoothTracker.zoomForSpeed(t.speedMs);
    if (_mapReady && t.lat != null) {
      _map.move(LatLng(t.lat!, t.lon!), _zoom);
    }
    nav.start();
    // Navigation ohne Aufzeichnung waere schade - die Fahrt gleich mit
    // aufzeichnen.
    if (!t.recording) widget.onToggleRide();
  }

  void _onNavChanged() {
    final nav = _nav;
    if (nav == null || !mounted) return;
    if (!t.foreground) {
      // Nach einer Neuberechnung im Hintergrund die Linie trotzdem
      // uebernehmen - gezeichnet wird beim naechsten Hinsehen.
      if (!identical(nav.plan, _route)) {
        _route = nav.plan;
        _routeLine = nav.plan.points
            .map((p) => LatLng(p.lat, p.lon))
            .toList(growable: false);
      }
      return;
    }
    // Nach einer Neuberechnung die neue Linie zeigen.
    if (!identical(nav.plan, _route)) {
      _route = nav.plan;
      _routeLine = nav.plan.points
          .map((p) => LatLng(p.lat, p.lon))
          .toList(growable: false);
      _pois = [..._pois.where((p) => p.source == 'osm'), ...nav.plan.pois];
    }
    setState(() {});
  }

  void _stopNav() {
    final nav = _nav;
    if (nav == null) return;
    nav.removeListener(_onNavChanged);
    nav.dispose();
    Voice.instance.stop();
    t.setNavigating(false);
    setState(() {
      _nav = null;
      _follower = _route != null ? RouteFollower(_route!) : null;
      _follow = null;
    });
    if (_mapReady) _map.rotate(0);
  }

  // ------------------------------------------------------------------
  // Aktionen
  // ------------------------------------------------------------------
  /// GPX laden: Datei auswaehlen (Downloads, Drive, Dateimanager) oder
  /// den Inhalt einfuegen.
  Future<void> _importGpx() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.folder_open, color: cool),
            title: const Text('GPX-Datei auswählen',
                style: TextStyle(fontSize: 12.5, color: chalk)),
            subtitle: const Text('Downloads, Google Drive, Dateimanager ...',
                style: TextStyle(fontSize: 10, color: steel)),
            onTap: () => Navigator.pop(ctx, 'file'),
          ),
          ListTile(
            leading: const Icon(Icons.content_paste, color: cool),
            title: const Text('GPX-Text einfügen',
                style: TextStyle(fontSize: 12.5, color: chalk)),
            onTap: () => Navigator.pop(ctx, 'paste'),
          ),
        ]),
      ),
    );
    if (how == 'file') {
      await _pickGpxFile();
    } else if (how == 'paste') {
      await _pasteGpx();
    }
  }

  Future<void> _pickGpxFile() async {
    PlatformFile? f;
    try {
      f = await FilePicker.pickFile();
    } catch (_) {
      if (mounted) toast(context, 'Dateiauswahl nicht möglich');
      return;
    }
    if (f == null) return;
    String xml;
    try {
      xml = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    } catch (_) {
      if (mounted) toast(context, 'Datei ließ sich nicht lesen');
      return;
    }
    _loadGpx(xml, fallbackTitle: f.name.replaceAll(RegExp(r'\.gpx$', caseSensitive: false), ''));
  }

  void _loadGpx(String xml, {String? fallbackTitle}) {
    final plan = GpxService.parseRoute(xml, fallbackTitle: fallbackTitle);
    if (plan.isEmpty) {
      toast(context, 'Keine GPX-Punkte gefunden');
      return;
    }
    _setRoute(plan);
    toast(context, 'Route geladen: ${plan.distanceKm.toStringAsFixed(1)} km');
  }

  Future<void> _pasteGpx() async {
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

    if (mounted) _loadGpx(xml);
  }

  void _setRoute(RoutePlan plan, {bool keepVariants = false}) {
    _stopNav();
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
    // Karte entlang der Route vorab aufs Handy laden - fuer Funkloecher.
    _autoSaveRoute(plan);
  }

  Future<void> _autoSaveRoute(RoutePlan plan) async {
    await _offline.cache();
    if (!_offline.autoRoute || !identical(_route, plan)) return;
    _offline.saveRoute(plan.points, label: plan.title ?? 'Route');
  }

  void _nextVariant() {
    if (_variants.length < 2 || _nav != null) return;
    _variantIdx = (_variantIdx + 1) % _variants.length;
    _setRoute(_variants[_variantIdx], keepVariants: true);
  }

  void _clearRoute() {
    _stopNav();
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
    // Schluessel koennte im Planer neu eingetragen worden sein.
    await _loadTrafficKey();
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

  Future<void> _shareGpx() async {
    final r = _route;
    if (r == null) return;
    final msg = await GpxService.share(
      '${(r.title ?? 'route')}.gpx',
      GpxService.routeToGpx(r),
      subject: r.title,
    );
    if (msg != null && mounted) toast(context, msg);
  }

  Future<void> _open(Uri uri) async {
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) toast(context, 'Keine passende App gefunden');
  }

  /// Route an eine andere Navi-App uebergeben.
  void _showExport() {
    final r = _route;
    if (r == null) return;
    final from = _nav?.alongM ?? 0;
    final google = ExternalNav.googleMaps(r, fromM: from);
    final (target, targetName) = ExternalNav.nextTarget(r, fromM: from);

    Widget tile(IconData icon, String title, String sub, VoidCallback onTap) =>
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: cool, size: 20),
          title: Text(title,
              style: const TextStyle(fontSize: 12.5, color: chalk)),
          subtitle: Text(sub,
              style: const TextStyle(fontSize: 10, color: steel, height: 1.3)),
          onTap: onTap,
        );

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            children: [
              const Text('IN NAVI-APP ÖFFNEN',
                  style: TextStyle(
                      fontSize: 12, letterSpacing: 2, color: chalk)),
              const SizedBox(height: 4),
              const Text(
                'Die exakte Tour überträgt nur die GPX-Datei. Links an '
                'Google & Co. geben Zwischenpunkte auf der Tour vor - die '
                'App rechnet dazwischen selbst.',
                style: TextStyle(fontSize: 10, color: steel, height: 1.4),
              ),
              const SizedBox(height: 8),
              tile(
                Icons.route,
                'GPX-Datei (exakte Tour)',
                'TomTom GO, Garmin, Kurviger, Calimoto, OsmAnd, '
                    'MyRoute-app ... - im Teilen-Menü die App wählen',
                () {
                  Navigator.pop(ctx);
                  _shareGpx();
                },
              ),
              for (final g in google)
                tile(Icons.map, g.label, g.detail ?? '', () => _open(g.uri)),
              tile(Icons.navigation, 'Waze',
                  'Nur ein Ziel möglich: $targetName',
                  () => _open(ExternalNav.waze(target))),
              if (Platform.isIOS)
                tile(Icons.map_outlined, 'Apple Karten',
                    'Nur ein Ziel möglich: $targetName',
                    () => _open(ExternalNav.appleMaps(target))),
              if (Platform.isAndroid)
                tile(Icons.open_in_new, 'Andere Navi-App',
                    'TomTom GO, Sygic, HERE, Magic Earth ... - Ziel: $targetName',
                    () => _open(ExternalNav.geo(target, targetName))),
            ],
          ),
        ),
      ),
    );
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
              urlTemplate: osmUrlTemplate,
              userAgentPackageName: 'de.schraeglage.app',
              maxNativeZoom: 19,
              // Kacheln vom Handy, im Funkloch auch vergroesserte
              // groebere Kacheln statt leerer Flaeche.
              tileProvider: OfflineMaps.tiles,
            ),
            if (_tomtomKey.isNotEmpty && _showFlow)
              TileLayer(
                // Verkehrsfluss relativ zur freien Fahrt; transparent
                // ueber der Karte.
                urlTemplate: 'https://api.tomtom.com/traffic/map/4/tile/flow/'
                    'relative0/{z}/{x}/{y}.png?key={key}&thickness=6',
                additionalOptions: {'key': _tomtomKey},
                userAgentPackageName: 'de.schraeglage.app',
                maxNativeZoom: 18,
                tileDisplay: const TileDisplay.fadeIn(),
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
            // Eigene Position: eigene Schicht, die sich 30-mal je Sekunde
            // bewegt, ohne dass die ganze Karte neu aufgebaut wird.
            ValueListenableBuilder<(LatLng, double)?>(
              valueListenable: _rider,
              builder: (context, r, _) => r == null
                  ? const SizedBox.shrink()
                  : MarkerLayer(markers: [
                      Marker(
                        point: r.$1,
                        width: 34,
                        height: 34,
                        child: _nav != null || t.speedKmh > 5
                            // Pfeil in Fahrtrichtung (dreht mit der Karte).
                            ? Transform.rotate(
                                angle: r.$2 * math.pi / 180,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: panel,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: chalk, width: 2),
                                  ),
                                  child: const Icon(Icons.navigation,
                                      size: 22, color: signal),
                                ),
                              )
                            : Container(
                                margin: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: signal,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: chalk, width: 2.5),
                                ),
                              ),
                      ),
                    ]),
            ),
            // Pflichtangabe zur Kartenquelle. Liegt oberhalb des
            // Tastenbands, damit sie nicht verdeckt wird.
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 4, bottom: _nav != null ? 215 : 104),
                child: const MapAttribution(),
              ),
            ),
          ],
        ),

        // Kopfzeile: Abbiegehinweis bei Navigation, sonst Route-Info
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: _nav != null ? _navTop(_nav!) : _topBar(),
        ),

        // Bedienleiste unten
        Positioned(
          left: 12,
          right: 12,
          bottom: 10,
          child: _nav != null ? _navBottom(_nav!) : _bottomBar(),
        ),

        Positioned(
          right: 12,
          top: (_nav != null ? 150 : 80) + (_tomtomKey.isNotEmpty ? 44 : 0),
          child: _offlineButton(),
        ),
        if (_tomtomKey.isNotEmpty)
          Positioned(
            right: 12,
            top: _nav != null ? 150 : 80,
            child: InkWell(
              onTap: () => setState(() => _showFlow = !_showFlow),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: panel.withValues(alpha: 0.94),
                  border: Border.all(color: _showFlow ? signal : line),
                ),
                child: Icon(Icons.traffic,
                    size: 18, color: _showFlow ? signal : steel),
              ),
            ),
          ),
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

  // ------------------------------------------------------------------
  // Offline-Karten
  // ------------------------------------------------------------------
  Widget _offlineButton() {
    final job = _offline.job;
    final running = job?.running == true;
    final off = _offline.offline.value;
    return InkWell(
      onTap: _showOffline,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: panel.withValues(alpha: 0.94),
          border: Border.all(color: off ? amber : (running ? cool : line)),
        ),
        child: SizedBox(
          width: 18,
          height: 18,
          child: running
              ? CircularProgressIndicator(
                  value: job!.progress,
                  strokeWidth: 2,
                  color: cool,
                  backgroundColor: line,
                )
              : Icon(off ? Icons.cloud_off : Icons.download_for_offline,
                  size: 18, color: off ? amber : steel),
        ),
      ),
    );
  }

  void _showOffline() {
    final visible = _mapReady ? _map.camera.visibleBounds : null;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: _offline,
          builder: (ctx, _) => _offlineSheet(ctx, visible),
        ),
      ),
    );
  }

  Widget _offlineSheet(BuildContext ctx, LatLngBounds? visible) {
    final job = _offline.job;
    const small = TextStyle(fontSize: 10, color: steel, height: 1.4);
    String areaInfo() {
      if (visible == null) return '';
      final z = OfflineMaps.areaMaxZoom(visible.south, visible.west,
          visible.north, visible.east, 8);
      final n = countTilesInBox(
          visible.south, visible.west, visible.north, visible.east,
          minZoom: 8, maxZoom: z);
      return 'Bis Zoomstufe $z · ca. ${formatBytes(n * avgTileBytes)}';
    }

    String routeInfo(RoutePlan r) {
      final n = _offline.routeTiles(r.points).length;
      return 'Streifen entlang der Tour · ca. ${formatBytes(n * avgTileBytes)}';
    }

    String jobText(OfflineJob j) {
      final r = j.result;
      if (r == null) {
        return '${j.label}: ${j.done} von ${j.total} Kacheln';
      }
      if (r.cancelled && r.failed > 0) {
        return '${j.label}: abgebrochen - kein Netz? '
            '${r.loaded + r.skipped} von ${j.total} gespeichert.';
      }
      if (r.cancelled) return '${j.label}: abgebrochen.';
      return '${j.label}: fertig, ${r.loaded + r.skipped} Kacheln auf dem Handy'
          '${r.failed > 0 ? ' (${r.failed} fehlgeschlagen)' : ''}.';
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        const Text('OFFLINE-KARTEN',
            style: TextStyle(fontSize: 12, letterSpacing: 2, color: chalk)),
        const SizedBox(height: 4),
        const Text(
          'Jede angesehene Karte bleibt auf dem Handy. Vorab geladene '
          'Strecken und Gebiete funktionieren auch im Funkloch - die '
          'Navigation läuft mit der gespeicherten Route weiter.',
          style: small,
        ),
        if (_offline.offline.value) ...[
          const SizedBox(height: 6),
          const Text('Gerade kein Netz - Karte kommt vom Handy.',
              style: TextStyle(fontSize: 10.5, color: amber)),
        ],
        if (job != null) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
              value: job.progress, color: cool, backgroundColor: line),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: Text(jobText(job), style: small)),
            if (job.running)
              TextButton(
                onPressed: _offline.cancel,
                child: const Text('ABBRECHEN',
                    style: TextStyle(fontSize: 10, color: amber)),
              ),
          ]),
        ],
        const SizedBox(height: 6),
        if (_route != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.route, color: cool, size: 20),
            title: const Text('Route offline speichern',
                style: TextStyle(fontSize: 12.5, color: chalk)),
            subtitle: Text(routeInfo(_route!), style: small),
            onTap: () => _offline.saveRoute(_route!.points,
                label: _route!.title ?? 'Route'),
          ),
        if (visible != null)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.crop_free, color: cool, size: 20),
            title: const Text('Sichtbaren Ausschnitt speichern',
                style: TextStyle(fontSize: 12.5, color: chalk)),
            subtitle: Text(areaInfo(), style: small),
            onTap: () => _offline.saveArea(
                visible.south, visible.west, visible.north, visible.east),
          ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          activeTrackColor: signal,
          inactiveTrackColor: line,
          title: const Text('Geplante Routen automatisch speichern',
              style: TextStyle(fontSize: 12.5, color: chalk)),
          subtitle: const Text(
              'Lädt die Karte entlang jeder neuen Route gleich mit. '
              'Braucht mobile Daten - im WLAN planen spart Datenvolumen.',
              style: small),
          value: _offline.autoRoute,
          onChanged: (v) => _offline.setAutoRoute(v),
        ),
        FutureBuilder<TileCacheStats>(
          future: _offline.stats(),
          builder: (ctx, snap) {
            final s = snap.data;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sd_storage, color: steel, size: 20),
              title: Text(
                  s == null
                      ? 'Speicher wird gezählt ...'
                      : 'Belegt: ${formatBytes(s.bytes)} (${s.tiles} Kacheln)',
                  style: const TextStyle(fontSize: 12, color: chalk)),
              subtitle: const Text(
                  'Höchstens 600 MB - älteste Kacheln werden automatisch '
                  'gelöscht.',
                  style: small),
              trailing: TextButton(
                onPressed: () async {
                  await _offline.clear();
                  PaintingBinding.instance.imageCache.clear();
                },
                child: const Text('LEEREN',
                    style: TextStyle(fontSize: 10, color: amber)),
              ),
            );
          },
        ),
      ],
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

    for (final inc in _nav?.ahead ?? _route?.traffic ?? const <TrafficIncident>[]) {
      out.add(Marker(
        point: LatLng(inc.points.first.lat, inc.points.first.lon),
        width: 28,
        height: 28,
        child: GestureDetector(
          onTap: () => toast(context,
              [inc.label, if (inc.description != null) inc.description!].join(' · ')),
          child: Container(
            decoration: BoxDecoration(
              color: panel,
              shape: BoxShape.circle,
              border: Border.all(color: redline, width: 2),
            ),
            child: Icon(_trafficIcon(inc.category), size: 15, color: redline),
          ),
        ),
      ));
    }

    for (final p in _pois) {
      final info = [
        p.kind.label,
        p.displayName,
        if (_detailOf(p) != null) _detailOf(p)!,
        if (p.note != null) p.note!,
      ].join(' · ');
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

  /// Zusatzangabe, aber nicht doppelt ("Jet · JET").
  static String? _detailOf(Poi p) {
    final d = p.detail;
    if (d == null || d.trim().isEmpty) return null;
    final a = d.trim().toLowerCase(), b = p.displayName.trim().toLowerCase();
    if (a == b || b.contains(a)) return null;
    return d;
  }

  static IconData _trafficIcon(TrafficCategory c) => switch (c) {
        TrafficCategory.jam => Icons.traffic,
        TrafficCategory.closed => Icons.block,
        TrafficCategory.laneClosed => Icons.merge,
        TrafficCategory.roadworks => Icons.construction,
        TrafficCategory.accident => Icons.car_crash,
        TrafficCategory.weather => Icons.cloud,
        _ => Icons.warning_amber,
      };

  static IconData maneuverIcon(int type) => switch (type) {
        ManeuverType.start => Icons.trip_origin,
        ManeuverType.slightRight => Icons.turn_slight_right,
        ManeuverType.right => Icons.turn_right,
        ManeuverType.sharpRight => Icons.turn_sharp_right,
        ManeuverType.uturnRight => Icons.u_turn_right,
        ManeuverType.uturnLeft => Icons.u_turn_left,
        ManeuverType.sharpLeft => Icons.turn_sharp_left,
        ManeuverType.left => Icons.turn_left,
        ManeuverType.slightLeft => Icons.turn_slight_left,
        ManeuverType.rampRight || ManeuverType.exitRight => Icons.ramp_right,
        ManeuverType.rampLeft || ManeuverType.exitLeft => Icons.ramp_left,
        ManeuverType.stayRight => Icons.fork_right,
        ManeuverType.stayLeft => Icons.fork_left,
        ManeuverType.merge => Icons.merge,
        ManeuverType.roundaboutEnter || ManeuverType.roundaboutExit =>
          Icons.roundabout_right,
        ManeuverType.ferry => Icons.directions_boat,
        _ when ManeuverType.isDestination(type) => Icons.flag,
        _ => Icons.straight,
      };

  static String _fmtDist(double m) {
    if (m < 0) m = 0;
    if (m < 1000) {
      final r = m < 200 ? (m / 10).round() * 10 : (m / 50).round() * 50;
      return '$r m';
    }
    return _fmtKm(m);
  }

  static String _fmtClock(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

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
                            if (_detailOf(p) != null) _detailOf(p)!,
                          ].join(' · '),
                          style: const TextStyle(fontSize: 11, color: chalk),
                        ),
                      ),
                    ]),
                  ),
              ],
              if (r.traffic.isNotEmpty) ...[
                const SizedBox(height: 10),
                const TinyLabel('VERKEHRSLAGE AN DER ROUTE'),
                const SizedBox(height: 4),
                for (final i in r.traffic)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_trafficIcon(i.category), size: 14, color: redline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            [
                              'km ${(i.alongM / 1000).round()}: ${i.label}',
                              if (i.description != null) i.description!,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11, color: chalk),
                          ),
                        ),
                      ],
                    ),
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
              label: 'NAVI-APP',
              onTap: _showExport,
            ),
          ),
        ],
      ]),
      const SizedBox(height: 8),
      Row(children: [
        if (_route != null) ...[
          Expanded(
            child: FlatButton2(
              label: 'NAVIGATION',
              color: signal,
              strong: true,
              onTap: _startNav,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: FlatButton2(
            label: t.recording ? 'FAHRT BEENDEN' : 'FAHRT STARTEN',
            color: t.recording ? amber : (_route != null ? cool : signal),
            strong: _route == null || t.recording,
            onTap: widget.onToggleRide,
          ),
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------------
  // Navigationsanzeige
  // ------------------------------------------------------------------
  Widget _navTop(NavigationSession nav) {
    final step = nav.nextStep;
    final then = nav.thenStep;
    final f = nav.follow;
    final offer = nav.offer;
    final children = <Widget>[];

    if (nav.rerouting) {
      children.add(const Row(children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(color: signal, strokeWidth: 2),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Text('Route wird neu berechnet ...',
              style: TextStyle(fontSize: 14, color: chalk)),
        ),
      ]));
    } else if (step != null) {
      children.add(Row(children: [
        Icon(maneuverIcon(step.type), size: 44, color: signal),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  _fmtDist(nav.onRoute && _tracker.shownAlongM != null
                      ? nav.distanceToNextFrom(_tracker.shownAlongM!)
                      : nav.distanceToNext),
                  style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: chalk,
                      height: 1.1)),
              Text(step.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: chalk)),
            ],
          ),
        ),
        if (then != null)
          Column(children: [
            const Text('DANN',
                style: TextStyle(fontSize: 8, letterSpacing: 1.2, color: steel)),
            Icon(maneuverIcon(then.type), size: 22, color: steel),
          ]),
      ]));
    } else {
      children.add(const Text('Der Route folgen',
          style: TextStyle(fontSize: 14, color: chalk)));
    }

    if (f != null && f.isOffRoute && !nav.rerouting) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'ABSEITS DER ROUTE · ${_fmtDist(f.offRouteM)}',
          style: const TextStyle(fontSize: 10, letterSpacing: 1.2, color: amber),
        ),
      ));
    }
    if (nav.banner != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(nav.banner!,
            style: const TextStyle(fontSize: 11, color: cool)),
      ));
    }
    if (offer != null) {
      children.add(Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(border: Border.all(color: redline)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(_trafficIcon(offer.category), size: 16, color: redline),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${offer.label} in ${_fmtDist(offer.alongM - nav.alongM)}',
                  style: const TextStyle(fontSize: 12, color: chalk),
                ),
              ),
            ]),
            if (offer.description != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(offer.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: steel)),
              ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: FlatButton2(
                  label: 'UMFAHREN',
                  color: signal,
                  strong: true,
                  onTap: () => nav.avoidIncident(offer),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FlatButton2(
                  label: 'BLEIBEN',
                  onTap: nav.dismissOffer,
                ),
              ),
            ]),
          ],
        ),
      ));
    }
    if (nav.trafficError != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(nav.trafficError!,
            style: const TextStyle(fontSize: 9, color: steel)),
      ));
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: panel.withValues(alpha: 0.96),
        border: Border.all(color: f?.isOffRoute == true ? amber : line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _navBottom(NavigationSession nav) {
    final stop = nav.nextStop;
    final delay = nav.ahead
        .where((i) => i.alongM > nav.alongM)
        .fold<int>(0, (s, i) => s + i.delaySec);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: panel.withValues(alpha: 0.96),
          border: Border.all(color: line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text(_fmtKm(nav.remainingM),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700, color: chalk)),
              const SizedBox(width: 10),
              Text(_fmtDuration(nav.remainingTime.inSeconds),
                  style: const TextStyle(fontSize: 12, color: steel)),
              const Spacer(),
              Text('AN ${_fmtClock(nav.eta)}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: signal)),
            ]),
            if (delay >= 60)
              Text('davon ca. ${(delay / 60).round()} min Verzögerung durch Verkehr',
                  style: const TextStyle(fontSize: 9.5, color: redline)),
            if (stop != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Icon(_poiIcon(stop.poi.kind),
                      size: 14, color: _poiColor(stop.poi.kind)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${stop.poi.displayName} in ${_fmtDist(stop.distanceM)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: chalk),
                    ),
                  ),
                ]),
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: _mapBtn(
            icon: Icons.block,
            label: 'SPERRUNG',
            onTap: () async {
              final ok = await nav.avoidAhead();
              if (!ok && mounted) toast(context, 'Keine Umleitung möglich');
            },
          ),
        ),
        const SizedBox(width: 8),
        if (stop != null) ...[
          Expanded(
            child: _mapBtn(
              icon: Icons.skip_next,
              label: 'STOPP ÜBERSPR.',
              onTap: nav.skipNextStop,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: _mapBtn(
            icon: Icons.refresh,
            label: 'NEU',
            onTap: nav.rerouteNow,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _mapBtn(
            icon: Icons.ios_share,
            label: 'NAVI-APP',
            onTap: _showExport,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _mapBtn(
            icon: _autoFollow ? Icons.navigation : Icons.location_searching,
            label: 'FOLGEN',
            active: _autoFollow,
            onTap: () => setState(() => _autoFollow = !_autoFollow),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: FlatButton2(
            label: 'NAVIGATION BEENDEN',
            color: amber,
            onTap: _stopNav,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FlatButton2(
            label: t.recording ? 'FAHRT BEENDEN' : 'FAHRT STARTEN',
            color: t.recording ? amber : signal,
            onTap: widget.onToggleRide,
          ),
        ),
      ]),
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

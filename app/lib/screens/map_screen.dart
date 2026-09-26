import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../build_flavor.dart';
import '../models/route_plan.dart';
import '../services/curve_warning.dart';
import '../services/drive_sim.dart';
import '../services/external_nav.dart';
import '../services/geo.dart';
import '../services/fuel_prices.dart';
import '../services/geocoder.dart';
import '../services/gpx_service.dart';
import '../services/group_ride.dart';
import '../services/headset.dart';
import '../services/lanes.dart';
import '../services/navigation.dart';
import '../services/offline_maps.dart';
import '../services/offline_router.dart';
import '../services/poi_service.dart';
import '../services/route_follow.dart';
import '../services/route_patch.dart';
import '../services/route_weather.dart';
import '../services/smooth_position.dart';
import '../services/speed_cameras.dart';
import '../services/speed_limits.dart';
import '../services/routing_engine.dart';
import '../services/routing_settings.dart';
import '../services/telemetry.dart';
import '../services/tour_store.dart';
import '../services/vector_map.dart';
import '../services/traffic_eta.dart';
import '../services/tile_cache.dart';
import '../services/voice.dart';
import '../theme.dart';
import '../widgets/base_map.dart';
import '../widgets/map_attribution.dart';
import 'groups_screen.dart';
import 'route_planner_screen.dart';
import 'tours_screen.dart';

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
    VectorMap.instance.addListener(_onOffline);
    VectorMap.instance.init();
    if (kTestBuild) {
      _hub.addListener(_onGroupChanged);
      _onGroupChanged();
    }
    if (kTestBuild) {
      Headset.instance.addListener(_onOffline);
      Headset.instance.init();
      _buttonSub = Headset.instance.buttons.listen(_onHeadsetButton);
    }
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
    _stopSim();
    t.removeListener(_onTick);
    _offline.removeListener(_onOffline);
    _offline.offline.removeListener(_onOffline);
    VectorMap.instance.removeListener(_onOffline);
    _hub.removeListener(_onGroupChanged);
    for (final sub in _voiceSubs.values) {
      sub.cancel();
    }
    _buttonSub?.cancel();
    _pttTimer?.cancel();
    Headset.instance.removeListener(_onOffline);
    _ticker.dispose();
    _rider.dispose();
    _nav?.dispose();
    super.dispose();
  }

  /// Nachtkarte? Nach Einstellung, bei "automatisch" nach Sonnenstand
  /// am eigenen Standort.
  bool get _night =>
      VectorMap.instance.nightAt(DateTime.now(), t.lat, t.lon);

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
      // Ohne Navigation ist die Karte genordet: Pfeil ebenfalls in den
      // freien Bereich zwischen den Feldern.
      final z = _map.camera.zoom;
      final mpp = 156543.03 *
          math.cos(ll.latitude * math.pi / 180) /
          math.pow(2, z);
      final dy = _riderOffsetPx();
      _map.move(
          dy >= 0
              ? const Distance().offset(ll, mpp * dy, 0)
              : const Distance().offset(ll, mpp * -dy, 180),
          z);
    }
  }

  void _onTick() {
    if (!mounted) return;
    // Gruppen sehen mich nur, solange ich fahre (Aufzeichnung/Navi).
    if (kTestBuild &&
        _hub.sessions.isNotEmpty &&
        t.lat != null &&
        (t.recording || _nav != null)) {
      unawaited(_hub.sendPosition(t.lat!, t.lon!, math.max(0, t.speedMs)));
    }
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
  // Fuer die Lage des eigenen Pfeils: Karte und die Felder darueber.
  final _stackKey = GlobalKey();
  final _topKey = GlobalKey();
  final _bottomKey = GlobalKey();

  /// Wie weit der eigene Pfeil unter der Kartenmitte stehen soll (Pixel).
  ///
  /// Vorher fest 22 % der Bildschirmhoehe - mit Abbiegefeld oben und
  /// Tempolimit, Restzeit und Knoepfen unten lag der Pfeil dann HINTER
  /// den Knoepfen. Jetzt wird der freie Bereich zwischen oberem und
  /// unterem Feld gemessen, und der Pfeil steht etwas unter dessen Mitte
  /// (60 %) - so sieht man sich selbst und die Strecke voraus.
  double _riderOffsetPx() {
    RenderBox? box(GlobalKey k) {
      final o = k.currentContext?.findRenderObject();
      return o is RenderBox && o.hasSize ? o : null;
    }

    final stack = box(_stackKey);
    if (stack == null) return 0;
    final origin = stack.localToGlobal(Offset.zero).dy;
    final h = stack.size.height;
    var freeTop = 0.0, freeBottom = h;
    final top = box(_topKey);
    if (top != null) {
      freeTop = top.localToGlobal(Offset.zero).dy - origin + top.size.height;
    }
    final bottom = box(_bottomKey);
    if (bottom != null) {
      freeBottom = bottom.localToGlobal(Offset.zero).dy - origin;
    }
    if (freeBottom - freeTop < 80) return 0;
    final y = freeTop + (freeBottom - freeTop) * 0.6;
    return y - h / 2;
  }

  void _followCourseUp(LatLng at, double heading) {
    final target = SmoothTracker.zoomForSpeed(t.speedMs);
    _zoom += (target - _zoom) * 0.03;
    final mpp =
        156543.03 * math.cos(at.latitude * math.pi / 180) / math.pow(2, _zoom);
    // Kartenmitte so verschieben, dass der Pfeil im freien Bereich steht.
    final dy = _riderOffsetPx();
    final c = dy >= 0
        ? const Distance().offset(at, mpp * dy, heading)
        : const Distance().offset(at, mpp * -dy, (heading + 180) % 360);
    _map.moveAndRotate(c, _zoom, -heading);
  }

  // ------------------------------------------------------------------
  // Navigation
  // ------------------------------------------------------------------
  // ------------------------------------------------------------------
  // Probefahrt (Simulation)
  // ------------------------------------------------------------------
  DriveSimulator? _sim;
  Timer? _simTimer;
  double _simFactor = 1;
  bool _simPaused = false;
  Object? _simLimits;

  Future<void> _startSim() async {
    if (!kTestBuild) return;
    final r = _route;
    if (r == null || _nav != null) return;
    if (t.recording) {
      toast(context, 'Erst die laufende Aufzeichnung beenden');
      return;
    }
    final sim = DriveSimulator()..setRoute(r.points);
    t.simulating = true;
    _sim = sim;
    _simFactor = 1;
    _simPaused = false;
    _simLimits = null;
    // Erste Position sofort, damit die Navigation am Start beginnt.
    final f = sim.step1(0);
    t.simulateFix(f.point.lat, f.point.lon, 0, f.heading);
    await _startNav(simulated: true);
    _restartSimTimer();
  }

  /// Ein Takt je Sekunde Fahrzeit - bei 2x/5x entsprechend oefter, damit
  /// Karte und Ansagen wie in echt aussehen, nur schneller.
  void _restartSimTimer() {
    _simTimer?.cancel();
    _simTimer = Timer.periodic(
        Duration(milliseconds: (1000 / _simFactor).round()), (_) => _simTick());
  }

  void _simTick() {
    final sim = _sim, nav = _nav;
    if (sim == null || nav == null || _simPaused) return;
    // Nach Neuberechnung/Umfahrung der neuen Linie folgen.
    sim.setRoute(nav.plan.points);
    final lim = nav.speedLimits;
    if (lim.isNotEmpty && !identical(lim, _simLimits)) {
      _simLimits = lim;
      sim.setLimits(lim);
    }
    final f = sim.step1(1.0);
    t.simulateFix(f.point.lat, f.point.lon, f.speedMs, f.heading);
  }

  void _stopSim() {
    _simTimer?.cancel();
    _simTimer = null;
    if (_sim != null) {
      _sim = null;
      t.simulating = false;
    }
  }

  Widget _simBar() {
    final sim = _sim!;
    Widget btn(String label, VoidCallback onTap, {bool active = false}) =>
        Expanded(
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: panel.withValues(alpha: 0.96),
                border: Border.all(color: active ? cool : line),
              ),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                      color: active ? cool : chalk)),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          color: cool,
          child: const Text('PROBEFAHRT',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w800,
                  color: asphalt)),
        ),
        const SizedBox(width: 6),
        btn(_simPaused ? '▶ WEITER' : '❚❚ PAUSE',
            () => setState(() => _simPaused = !_simPaused),
            active: _simPaused),
        const SizedBox(width: 6),
        btn('${_simFactor.round()}× TEMPO', () {
          setState(() => _simFactor = _simFactor >= 5 ? 1 : (_simFactor == 1 ? 2 : 5));
          _restartSimTimer();
        }),
        const SizedBox(width: 6),
        btn(sim.detouring ? 'VERFAHREN ...' : 'VERFAHREN', () {
          sim.detour();
          setState(() {});
          toast(context, 'Simuliert: falsch abgebogen');
        }, active: sim.detouring),
      ]),
    );
  }

  Future<void> _startNav({bool simulated = false}) async {
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
      limits: settings.limitSource(),
      lanes: OverpassLanes.instance,
      // Neuberechnung ohne Netz - vorerst nur in der Test-App.
      offlineRouter: kTestBuild
          ? OfflineRerouter(
              (k) async => (await VectorMap.instance.cache()).read(k))
          : null,
      etaSource: settings.tomtomKey.trim().isEmpty
          ? null
          : TomTomEta(settings.tomtomKey.trim()),
      speedWarning: settings.speedWarn,
      curveWarning: settings.curveWarn,
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
    // Test-App: ohne Headset hoert man die Ansagen unter dem Helm nicht.
    if (kTestBuild && settings.voice && mounted) {
      await Headset.instance.refresh();
      final st = Headset.instance.status;
      if (!mounted) return;
      if (!st.connected) {
        toast(context,
            'Kein Headset verbunden - Ansagen kommen aus dem Handy-Lautsprecher');
      } else if (st.batteryLow) {
        toast(context, 'Headset-Akku nur noch ${st.battery} %');
      }
    }
    // Navigation ohne Aufzeichnung waere schade - die Fahrt gleich mit
    // aufzeichnen. (Nicht bei der Probefahrt - das ist keine Fahrt.)
    if (!simulated && !t.recording) widget.onToggleRide();
  }

  void _onNavChanged() {
    final nav = _nav;
    if (nav == null || !mounted) return;
    unawaited(_refreshNavWeather(nav));
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
    _stopSim();
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
            leading: const Icon(Icons.bookmarks, color: signal),
            title: const Text('Gespeicherte Touren',
                style: TextStyle(fontSize: 12.5, color: chalk)),
            subtitle: const Text('Eigene Touren und die zuletzt geplante',
                style: TextStyle(fontSize: 10, color: steel)),
            onTap: () => Navigator.pop(ctx, 'tours'),
          ),
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
    if (how == 'tours') {
      await _openTours();
    } else if (how == 'file') {
      await _pickGpxFile();
    } else if (how == 'paste') {
      await _pasteGpx();
    }
  }

  // ------------------------------------------------------------------
  // Tour auf der Karte bearbeiten
  // ------------------------------------------------------------------
  final List<RoutePlan> _undo = [];

  /// Markierung der Stelle, die gerade bearbeitet wird.
  LatLng? _editPin;

  Future<void> _editAt(RoutePoint p) async {
    final r = _route;
    if (_nav != null || _busy) return;
    if (r == null) {
      // Ohne Route: dorthin fahren.
      await _goThere(p);
      return;
    }
    setState(() => _editPin = LatLng(p.lat, p.lon));
    final cum = cumulativeDistances(r.points);
    final hit = projectOnPolyline(p, r.points, cum);
    final onRoute = hit != null && hit.distanceM < 150;
    Poi? stop;
    for (final x in r.pois.where((x) => x.source == 'stop')) {
      if (dist(RoutePoint(x.lat, x.lon), p) < 200) stop = x;
    }
    final what = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              'Nur ein Stück von rund 8 km um die Stelle wird neu '
              'berechnet - der Rest der Tour bleibt, wie er ist.',
              style: TextStyle(fontSize: 10, color: steel, height: 1.4),
            ),
          ),
          if (!onRoute)
            ListTile(
              leading: const Icon(Icons.add_location_alt, color: signal),
              title: const Text('Tour über diesen Punkt führen',
                  style: TextStyle(fontSize: 12.5, color: chalk)),
              onTap: () => Navigator.pop(ctx, 'via'),
            ),
          if (onRoute)
            ListTile(
              leading: const Icon(Icons.do_not_disturb_on, color: amber),
              title: const Text('Diese Straße meiden',
                  style: TextStyle(fontSize: 12.5, color: chalk)),
              subtitle: const Text('Baustelle, schlechter Belag, kennst du schon ...',
                  style: TextStyle(fontSize: 10, color: steel)),
              onTap: () => Navigator.pop(ctx, 'avoid'),
            ),
          if (stop != null)
            ListTile(
              leading: const Icon(Icons.wrong_location, color: amber),
              title: Text('Stopp entfernen: ${stop.displayName}',
                  style: const TextStyle(fontSize: 12.5, color: chalk)),
              onTap: () => Navigator.pop(ctx, 'stop'),
            ),
        ]),
      ),
    );
    if (what == null || !mounted) {
      if (mounted) setState(() => _editPin = null);
      return;
    }
    final settings = await RoutingSettings.load();
    final patcher = RoutePatcher(
      settings.engine(),
      r.request != null ? RoutingPrefs.of(r.request!) : const RoutingPrefs(),
    );
    setState(() => _busy = true);
    try {
      final base = engineRouteOf(r);
      final PatchResult res;
      var pois = r.pois;
      switch (what) {
        case 'via':
          res = await patcher.via(base, p);
        case 'avoid':
          res = await patcher.avoidAt(base, p);
        default:
          res = await patcher.without(base, RoutePoint(stop!.lat, stop.lon));
          pois = [for (final x in r.pois) if (x.id != stop.id) x];
      }
      if (!mounted || !identical(_route, r)) return;
      _undo.add(r);
      if (_undo.length > 10) _undo.removeAt(0);
      // Automatischer Titel mit km-Angabe: an die neue Laenge anpassen.
      final km = (res.route.distanceM / 1000).round();
      final t = r.title;
      final title = t != null && RegExp(r'^Rundtour · \d+ km$').hasMatch(t)
          ? 'Rundtour · $km km'
          : t;
      final edited = planWith(r, res.route).copyWith(
        title: title,
        pois: pois,
        // Varianten und Verkehrslage gehoerten zur alten Linie.
        alternatives: const [],
        traffic: const [],
      );
      _setRoute(edited, keepUndo: true);
      final extra = res.extraM / 1000;
      final sign = extra >= 0 ? '+' : '−';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: panel,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 150),
        duration: const Duration(seconds: 8),
        shape: const RoundedRectangleBorder(
            side: BorderSide(color: line)),
        content: Text(
            'Tour geändert: $sign${extra.abs().toStringAsFixed(1).replaceAll('.', ',')} km',
            style: const TextStyle(color: chalk)),
        action: SnackBarAction(
          label: 'RÜCKGÄNGIG',
          textColor: signal,
          onPressed: _undoEdit,
        ),
      ));
    } on RouteException catch (e) {
      if (mounted) toast(context, 'Nicht möglich: ${e.message}');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _editPin = null;
        });
      }
    }
  }

  /// Einmalig erklaeren, dass man die Tour per langem Druck aendern kann.
  Future<void> _editHintOnce() async {
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool('hint_edit_tour') == true || !mounted) return;
    await sp.setBool('hint_edit_tour', true);
    if (mounted) {
      toast(context, 'Tipp: Lange auf die Karte drücken, um die Tour zu ändern');
    }
  }

  /// Lange auf die Karte gedrueckt, keine Route: "Hierhin fahren".
  Future<void> _goThere(RoutePoint p) async {
    setState(() => _editPin = LatLng(p.lat, p.lon));
    final named = await Geocoder.reverse(p.lat, p.lon);
    if (!mounted) return;
    final place = named ??
        Place(
          name: 'Punkt ${p.lat.toStringAsFixed(5)}, ${p.lon.toStringAsFixed(5)}',
          kind: 'Punkt auf der Karte',
          lat: p.lat,
          lon: p.lon,
        );
    final go = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.place, color: signal),
            title: Text(place.name,
                style: const TextStyle(fontSize: 13, color: chalk)),
            subtitle: Text(
                [place.detail, place.kind].where((x) => x.isNotEmpty).join(' · '),
                style: const TextStyle(fontSize: 10, color: steel)),
          ),
          ListTile(
            leading: const Icon(Icons.directions, color: cool),
            title: const Text('Hierhin fahren (Route planen)',
                style: TextStyle(fontSize: 12.5, color: chalk)),
            onTap: () => Navigator.pop(ctx, true),
          ),
        ]),
      ),
    );
    if (mounted) setState(() => _editPin = null);
    if (go != true || !mounted) return;
    await _openPlanner(dest: place);
  }

  void _undoEdit() {
    if (_undo.isEmpty || _nav != null) return;
    _setRoute(_undo.removeLast(), keepUndo: true);
  }

  Future<void> _openTours() async {
    final plan = await Navigator.push<RoutePlan>(
        context, MaterialPageRoute(builder: (_) => const ToursScreen()));
    if (plan != null && mounted) _setRoute(plan);
  }

  /// Aktuelle Route als Tour speichern.
  Future<void> _saveTour() async {
    final r = _route;
    if (r == null) return;
    final ctrl = TextEditingController(text: r.title ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(side: BorderSide(color: line)),
        title: const Text('TOUR SPEICHERN',
            style: TextStyle(fontSize: 12, letterSpacing: 2.5, color: chalk)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: chalk),
          decoration: const InputDecoration(hintText: 'Name der Tour'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ABBRECHEN',
                style: TextStyle(fontSize: 11, color: steel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('SPEICHERN',
                style: TextStyle(fontSize: 11, color: signal)),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null) return;
    final m = await (await TourStore.open()).save(r, title: name);
    if (mounted) toast(context, 'Gespeichert: ${m.title}');
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

  void _setRoute(RoutePlan plan,
      {bool keepVariants = false, bool keepUndo = false}) {
    _stopNav();
    // Neue Tour: die Bearbeitungsschritte der alten gelten nicht mehr.
    if (!keepUndo) _undo.clear();
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
    _prefetchLimits(plan);
    _loadCameras(plan);
    _loadWeather(plan);
    _loadFuelPrices(plan);
    _loadTrafficEta(plan);
    _editHintOnce();
    // Zuletzt geplante Route merken - uebersteht einen Neustart.
    TourStore.open().then((s) => s.saveLast(plan)).catchError((_) {});
  }

  // ------------------------------------------------------------------
  // Fahrzeit mit Verkehr (TomTom)
  // ------------------------------------------------------------------
  TrafficEta? _planEta;

  Future<void> _loadTrafficEta(RoutePlan plan) async {
    _planEta = null;
    final key = (await RoutingSettings.load()).tomtomKey.trim();
    if (key.isEmpty || !identical(_route, plan)) return;
    final e = await TomTomEta(key).forRoute(plan.points);
    if (mounted && identical(_route, plan)) setState(() => _planEta = e);
  }

  // ------------------------------------------------------------------
  // Spritpreise an den Tankstopps
  // ------------------------------------------------------------------
  Map<String, StopPrice> _fuelPrices = const {};

  Future<void> _loadFuelPrices(RoutePlan plan) async {
    _fuelPrices = const {};
    final s = await RoutingSettings.load();
    final fp = s.fuelPrices();
    if (fp == null || !plan.pois.any((p) => p.kind == PoiKind.fuel)) return;
    try {
      final m = await fp.forStops(plan.pois, s.fuelType);
      if (mounted && identical(_route, plan)) setState(() => _fuelPrices = m);
    } on FormatException catch (e) {
      if (mounted) toast(context, 'Spritpreise: ${e.message}');
    }
  }

  // ------------------------------------------------------------------
  // Wetter entlang der Route
  // ------------------------------------------------------------------
  RouteWeatherReport? _weather;
  RouteWeatherReport? _betterDeparture;
  DateTime? _weatherAt;
  double? _rainSaidAt;

  Future<void> _loadWeather(RoutePlan plan) async {
    setState(() {
      _weather = null;
      _betterDeparture = null;
    });
    final w = await RouteWeather.fetch(plan.points);
    if (!mounted || !identical(_route, plan) || w == null) return;
    final now = DateTime.now();
    setState(() {
      _weatherAt = now;
      _weather = w.at(now, plan.durationSec);
      _betterDeparture = w.betterDeparture(now, plan.durationSec);
    });
  }

  /// Waehrend der Navigation alle 30 Minuten fuer den Rest der Strecke
  /// neu holen - Vorhersagen aendern sich, und das Tempo auch.
  Future<void> _refreshNavWeather(NavigationSession nav) async {
    final last = _weatherAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 30)) {
      return;
    }
    _weatherAt = DateTime.now();
    final plan = nav.plan;
    final from = nav.alongM;
    final w = await RouteWeather.fetch(plan.points, fromM: from);
    if (!mounted || _nav != nav || w == null) return;
    final r = w.at(DateTime.now(), nav.remainingTime.inSeconds);
    setState(() {
      _weather = r;
      _betterDeparture = null;
    });
    // Neue Regenwarnung einmal ansagen - erneut nur, wenn sich die
    // Stelle deutlich verschoben hat.
    final wet = r.firstWet;
    final said = _rainSaidAt;
    if (wet != null && (said == null || (wet.alongM - said).abs() > 20000)) {
      final km = ((wet.alongM - nav.alongM) / 1000).round();
      Voice.instance.say(km < 2
          ? 'Achtung, Regen auf der Strecke.'
          : 'Achtung, Regen in etwa $km Kilometern.');
    }
    _rainSaidAt = wet?.alongM;
  }

  Widget _weatherChip() {
    final w = _weather;
    if (w == null) return const SizedBox.shrink();
    final warn = w.warnings();
    if (warn.isEmpty) return const SizedBox.shrink();
    final wet = w.firstWet != null;
    return InkWell(
      onTap: _nav == null ? _showRouteInfo : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: panel.withValues(alpha: 0.94),
          border: Border.all(color: wet ? cool : amber),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(wet ? Icons.umbrella : Icons.ac_unit,
              size: 14, color: wet ? cool : amber),
          const SizedBox(width: 6),
          Flexible(
            child: Text(warn.first,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: chalk)),
          ),
        ]),
      ),
    );
  }

  List<SpeedCamera> _cameras = const [];

  Future<void> _loadCameras(RoutePlan plan) async {
    _cameras = const [];
    final s = await RoutingSettings.load();
    if (!s.showCameras || !identical(_route, plan)) return;
    final c = await SpeedCameras.alongRoute(plan.points);
    if (!mounted || !identical(_route, plan) || c == null) return;
    setState(() => _cameras = c);
  }

  /// Blitzer nur bei der Planung - nie waehrend Navigation oder
  /// Aufzeichnung (in DE verboten, siehe speed_cameras.dart).
  bool get _camerasVisible =>
      _cameras.isNotEmpty && _nav == null && !t.recording;

  /// Tempolimits schon beim Planen holen - dann sind sie auch im
  /// Funkloch da, wenn die Navigation startet.
  Future<void> _prefetchLimits(RoutePlan plan) async {
    // Spurempfehlungen gleich mit holen - dann auch offline da.
    unawaited(OverpassLanes.instance
        .forRoute(plan.points, plan.steps)
        .catchError((_) => <int, LaneInfo>{}));
    final src = (await RoutingSettings.load()).limitSource();
    if (src == null || !identical(_route, plan)) return;
    try {
      await src.forRoute(plan.points);
    } catch (_) {
      // Ohne Netz: die Navigation versucht es spaeter noch einmal.
    }
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
    _undo.clear();
    setState(() {
      _route = null;
      _cameras = const [];
      _weather = null;
      _betterDeparture = null;
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

  Future<void> _openPlanner({Place? dest}) async {
    final plan = await Navigator.push<RoutePlan>(
      context,
      MaterialPageRoute(
        builder: (_) => RoutePlannerScreen(
          startLat: t.lat,
          startLon: t.lon,
          initialDest: dest,
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
      child: Stack(key: _stackKey, children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 13,
            // Lange druecken: Tour an dieser Stelle bearbeiten.
            onLongPress: (_, ll) => _editAt(RoutePoint(ll.latitude, ll.longitude)),
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
            baseMapLayer(night: _night),
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
                padding: EdgeInsets.only(
                    left: 4,
                    bottom: _nav == null
                        ? 104
                        : 237 +
                            (_nav!.speedLimit != null ||
                                    _nav!.curveAhead != null
                                ? 62
                                : 0)),
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
          child: KeyedSubtree(
              key: _topKey,
              child: _nav != null ? _navTop(_nav!) : _topBar()),
        ),

        // Bedienleiste unten
        Positioned(
          left: 12,
          right: 12,
          bottom: 10,
          child: KeyedSubtree(
              key: _bottomKey,
              child: _nav != null ? _navBottom(_nav!) : _bottomBar()),
        ),

        Positioned(
          left: 12,
          right: 60,
          top: _nav != null ? 150 : 80,
          child: Align(alignment: Alignment.topLeft, child: _weatherChip()),
        ),
        Positioned(
          right: 12,
          top: (_nav != null ? 150 : 80) + (_tomtomKey.isNotEmpty ? 44 : 0),
          child: _offlineButton(),
        ),
        Positioned(
          right: 12,
          top: (_nav != null ? 150 : 80) + (_tomtomKey.isNotEmpty ? 88 : 44),
          child: _styleButton(),
        ),
        // Gruppenfahrt: vorerst nur in der Test-App.
        if (kTestBuild)
          Positioned(
            right: 12,
            top: (_nav != null ? 150 : 80) + (_tomtomKey.isNotEmpty ? 132 : 88),
            child: _groupButton(),
          ),
        if (kTestBuild)
          Positioned(
            right: 12,
            top: (_nav != null ? 150 : 80) + (_tomtomKey.isNotEmpty ? 176 : 132),
            child: _headsetButton(),
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

  // ------------------------------------------------------------------
  // Kartendarstellung (Vektor hell/dunkel, klassisch)
  // ------------------------------------------------------------------
  Widget _styleButton() {
    final night = _night && VectorMap.instance.useVector;
    return InkWell(
      onTap: _showStyles,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: panel.withValues(alpha: 0.94),
          border: Border.all(color: line),
        ),
        child: Icon(night ? Icons.dark_mode : Icons.layers,
            size: 18, color: steel),
      ),
    );
  }

  void _showStyles() {
    final vm = VectorMap.instance;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: vm,
          builder: (ctx, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('KARTE',
                    style: TextStyle(
                        fontSize: 12, letterSpacing: 2, color: chalk)),
              ),
            ),
            for (final m in MapStyle.values)
              ListTile(
                dense: true,
                leading: Icon(
                    vm.style == m
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: vm.style == m ? signal : steel,
                    size: 20),
                title: Text(m.label,
                    style: const TextStyle(fontSize: 12.5, color: chalk)),
                onTap: () => vm.setStyle(m),
              ),
            if (!vm.ready && vm.style != MapStyle.classic)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Die Vektorkarte braucht einmal Internet, bis dahin '
                  'zeigt die App die klassische Karte.',
                  style: TextStyle(fontSize: 10, color: amber, height: 1.4),
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Vektorkarte: scharf in jeder Zoomstufe, nachts dunkel '
                '(blendet nicht im Helm), offline deutlich kleiner.',
                style: TextStyle(fontSize: 10, color: steel, height: 1.4),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Gruppenfahrt (Test-App)
  // ------------------------------------------------------------------
  final GroupHub _hub = GroupHub.instance;
  final Map<GroupSession, StreamSubscription<GroupVoice>> _voiceSubs = {};
  final Map<String, DateTime> _sosShown = {};

  /// Gruppen geaendert: Funk jeder Gruppe hoeren, Hilferufe melden.
  void _onGroupChanged() {
    for (final s in _hub.sessions) {
      _voiceSubs.putIfAbsent(s, () => s.voiceIn.listen(_onVoice));
    }
    _voiceSubs.removeWhere((s, sub) {
      if (_hub.sessions.contains(s)) return false;
      sub.cancel();
      return true;
    });
    for (final s in _hub.sessions) {
      final sos = s.lastSos;
      if (sos == null || _sosShown[s.code] == sos.at) continue;
      _sosShown[s.code] = sos.at;
      Voice.instance.say(
          'Achtung: ${sos.name} ist möglicherweise gestürzt.', force: true);
      if (mounted) {
        toast(context, 'SOS: ${sos.name} ist möglicherweise gestürzt!');
      }
    }
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------
  // Helm-Headset und Funkgeraet (Test-App)
  // ------------------------------------------------------------------
  StreamSubscription<HeadsetButton>? _buttonSub;
  Timer? _pttTimer;

  /// Sprachnachricht der Gruppe: sofort uebers Headset abspielen.
  void _onVoice(GroupVoice v) {
    if (mounted) toast(context, 'Funk: ${v.from}');
    Headset.instance.play(v.audio);
  }

  /// Tasten am Headset (wenn eingeschaltet).
  void _onHeadsetButton(HeadsetButton b) {
    final nav = _nav;
    switch (b) {
      case HeadsetButton.playPause:
        Voice.instance.say(nav != null ? nav.repeatText() : _statusText(),
            repeat: true);
      case HeadsetButton.next:
        if (_hub.sessions.any((s) => s.shareLive)) {
          _pttToggle();
        } else {
          Voice.instance.say('Keine Gruppe zum Funken.', repeat: true);
        }
      case HeadsetButton.previous:
        Voice.instance.say(_statusText(), repeat: true);
    }
  }

  /// Kurzer Lagebericht zum Anhoeren.
  String _statusText() {
    final nav = _nav;
    final parts = <String>[];
    if (nav != null) {
      final km = nav.remainingM / 1000;
      parts.add('Noch ${km < 10 ? km.toStringAsFixed(1).replaceAll('.', ',') : km.round()} Kilometer');
      parts.add('Ankunft ${_fmtClock(nav.eta)}');
      final l = nav.speedLimit;
      if (l != null && !l.isUnlimited) parts.add('Tempolimit ${l.kmh}');
    } else {
      parts.add('Tempo ${t.speedKmh.round()}');
    }
    if (_hub.sessions.isNotEmpty) {
      final now = DateTime.now();
      final n = _hub.members.where((m) => !m.staleAt(now)).length;
      parts.add(n == 1 ? 'Ein Mitfahrer unterwegs' : '$n Mitfahrer unterwegs');
    }
    return '${parts.join('. ')}.';
  }

  /// Funkgeraet: Tippen startet, nochmal Tippen sendet (hoechstens 20 s).
  Future<void> _pttToggle() async {
    final h = Headset.instance;
    if (!_hub.sessions.any((s) => s.shareLive)) return;
    if (h.recording) {
      _pttTimer?.cancel();
      final rec = await h.stopRecording();
      if (rec == null) {
        if (mounted) toast(context, 'Zu kurz - nichts gesendet');
        return;
      }
      final ok = await _hub.sendVoice(rec.$1, rec.$2);
      if (mounted) {
        toast(context, ok ? 'Gesendet' : 'Nicht gesendet - zu lang oder offline');
      }
      return;
    }
    if (!await h.startRecording()) {
      if (mounted) toast(context, 'Mikrofon nicht verfügbar - Berechtigung?');
      return;
    }
    _pttTimer = Timer(Headset.maxRecord, _pttToggle);
    if (mounted) setState(() {});
  }

  Widget _pttButton() => ListenableBuilder(
        listenable: Headset.instance,
        builder: (context, _) => _pttButtonInner(),
      );

  Widget _pttButtonInner() {
    final rec = Headset.instance.recording;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: _pttToggle,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: rec ? redline : panel.withValues(alpha: 0.96),
            border: Border.all(color: rec ? redline : cool, width: 1.5),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(rec ? Icons.send : Icons.mic,
                size: 22, color: rec ? chalk : cool),
            const SizedBox(width: 8),
            Text(rec ? 'SENDEN' : 'SPRECHEN (GRUPPE)',
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w800,
                    color: rec ? chalk : cool)),
          ]),
        ),
      ),
    );
  }

  Widget _headsetButton() {
    final st = Headset.instance.status;
    final c = st.connected ? (st.batteryLow ? amber : signal) : steel;
    return InkWell(
      onTap: _showHeadset,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: panel.withValues(alpha: 0.94),
          border: Border.all(color: st.connected ? c : line),
        ),
        child: Icon(st.connected ? Icons.headset_mic : Icons.headset_off,
            size: 18, color: c),
      ),
    );
  }

  void _showHeadset() {
    final h = Headset.instance;
    h.refresh();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: h,
          builder: (ctx, _) {
            final st = h.status;
            const small = TextStyle(fontSize: 10, color: steel, height: 1.4);
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              children: [
                const Text('HELM-HEADSET',
                    style: TextStyle(
                        fontSize: 12, letterSpacing: 2, color: chalk)),
                const SizedBox(height: 8),
                Row(children: [
                  Icon(st.connected ? Icons.headset_mic : Icons.headset_off,
                      color: st.connected ? signal : steel),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        st.connected
                            ? '${st.label}${st.brand.isNotEmpty && !st.name.toLowerCase().contains(st.brand.toLowerCase()) ? ' (${st.brand})' : ''}'
                            : 'Kein Headset verbunden',
                        style: const TextStyle(fontSize: 13, color: chalk)),
                  ),
                ]),
                if (st.connected && st.battery < 0 && !st.btPermission)
                  TextButton(
                    onPressed: h.requestPermissions,
                    child: const Text('AKKUSTAND ANZEIGEN (ERLAUBEN)',
                        style: TextStyle(fontSize: 10, color: cool)),
                  ),
                const SizedBox(height: 6),
                const Text(
                  'Sena, Cardo, Interphone, Midland ... jedes Bluetooth-'
                  'Headset. Navi-Ansagen und Sprachnachrichten der Gruppe '
                  'kommen im Helm, Musik wird dabei leiser. Mit '
                  'Audio-Multitasking am Headset auch während des Intercoms.',
                  style: small,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: signal,
                  inactiveTrackColor: line,
                  title: const Text('Headset-Tasten steuern die App',
                      style: TextStyle(fontSize: 12.5, color: chalk)),
                  subtitle: const Text(
                      'Play/Pause: Ansage wiederholen · Weiter: Sprechen an '
                      'die Gruppe (nochmal: senden) · Zurück: Restweg, '
                      'Ankunft, Tempolimit. Solange an, steuern die Tasten '
                      'keine Musik.',
                      style: small),
                  value: h.buttonsOn,
                  onChanged: (v) => h.setButtons(v),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _groupButton() {
    final on = _hub.sessions.isNotEmpty;
    final now = DateTime.now();
    final n = _hub.members.where((m) => !m.staleAt(now)).length;
    final unread = _hub.unread;
    return InkWell(
      onTap: _openGroups,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: panel.withValues(alpha: 0.94),
          border: Border.all(color: unread > 0 ? signal : (on ? cool : line)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.groups, size: 18, color: on ? cool : steel),
          if (n > 0) ...[
            const SizedBox(width: 4),
            Text('$n', style: const TextStyle(fontSize: 11, color: cool)),
          ],
          if (unread > 0) ...[
            const SizedBox(width: 4),
            const Icon(Icons.chat_bubble, size: 11, color: signal),
          ],
        ]),
      ),
    );
  }

  Future<void> _openGroups() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupsScreen(
          route: _route,
          lat: t.lat,
          lon: t.lon,
          onLoadTour: (p) {
            if (mounted) _setRoute(p);
          },
          onGoTo: (p) {
            if (mounted) _openPlanner(dest: p);
          },
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
          visible.north, visible.east, 8,
          top: _offline.sourceMaxZoom);
      final n = countTilesInBox(
          visible.south, visible.west, visible.north, visible.east,
          minZoom: 8, maxZoom: z);
      return 'Bis Zoomstufe $z · ca. ${formatBytes(n * _offline.tileBytes)}';
    }

    String routeInfo(RoutePlan r) {
      final n = _offline.routeTiles(r.points).length;
      return 'Streifen entlang der Tour · ca. ${formatBytes(n * _offline.tileBytes)}';
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

    if (kTestBuild && _hub.sessions.isNotEmpty) {
      final now = DateTime.now();
      for (final m in _hub.members) {
        final stale = m.staleAt(now);
        out.add(Marker(
          point: LatLng(m.point.lat, m.point.lon),
          width: 90,
          height: 46,
          alignment: Alignment.topCenter,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              color: panel.withValues(alpha: 0.9),
              child: Text(m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 9.5, color: stale ? steel : chalk)),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: stale ? steel : cool,
                shape: BoxShape.circle,
                border: Border.all(color: chalk, width: 2),
              ),
              child: const Icon(Icons.two_wheeler, size: 12, color: asphalt),
            ),
          ]),
        ));
      }
    }

    final pin = _editPin;
    if (pin != null) {
      out.add(Marker(
        point: pin,
        width: 36,
        height: 36,
        alignment: Alignment.topCenter,
        child: const Icon(Icons.location_on, size: 36, color: signal),
      ));
    }

    if (_camerasVisible) {
      for (final c in _cameras) {
        out.add(Marker(
          point: LatLng(c.point.lat, c.point.lon),
          width: 22,
          height: 22,
          child: Container(
            decoration: BoxDecoration(
              color: panel,
              shape: BoxShape.circle,
              border: Border.all(color: amber, width: 1.5),
            ),
            child: const Icon(Icons.photo_camera, size: 12, color: amber),
          ),
        ));
      }
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
        // Probefahrt nur in der Test-App ("Schräglage Testing").
        if (r != null && kTestBuild)
          IconButton(
            tooltip: 'Probefahrt (Simulation)',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.play_circle_outline, size: 18, color: cool),
            onPressed: _startSim,
          ),
        if (r != null)
          IconButton(
            tooltip: 'Tour speichern',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.bookmark_add_outlined,
                size: 17, color: steel),
            onPressed: _saveTour,
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
              if (_planEta != null)
                row(
                    'Fahrzeit mit Verkehr jetzt',
                    '${_fmtDuration(_planEta!.travelSec)}'
                        '${_planEta!.delaySec >= 60 ? ' (+${(_planEta!.delaySec / 60).round()} min Stau)' : ''}'),
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
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Tipp: Lange auf die Karte drücken, um die Tour zu ändern - '
                  'über einen Punkt führen, Straße meiden, Stopp entfernen.',
                  style: TextStyle(fontSize: 10, color: cool, height: 1.4),
                ),
              ),
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
                            if (_fuelPrices[p.id] != null)
                              _fuelPrices[p.id]!.text,
                          ].join(' · '),
                          style: const TextStyle(fontSize: 11, color: chalk),
                        ),
                      ),
                    ]),
                  ),
                if (_fuelPrices.isNotEmpty)
                  const Text(FuelPrices.attribution,
                      style: TextStyle(fontSize: 8.5, color: steel)),
              ],
              if (_weather != null) ...[
                const SizedBox(height: 10),
                const TinyLabel('WETTER UNTERWEGS (ABFAHRT JETZT)'),
                const SizedBox(height: 4),
                for (final w in _weather!.warnings().isEmpty
                    ? [_weather!.summary()]
                    : _weather!.warnings())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(w,
                        style: const TextStyle(fontSize: 11, color: chalk)),
                  ),
                if (_betterDeparture != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Besser um ${RouteWeatherReport.clock(_betterDeparture!.departure)} '
                      'losfahren: ${_betterDeparture!.summary()}',
                      style: const TextStyle(fontSize: 11, color: signal),
                    ),
                  ),
                const Text(RouteWeather.attribution,
                    style: TextStyle(fontSize: 8.5, color: steel)),
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
            icon: Icons.bookmarks,
            label: 'TOUREN',
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
              fill: signal,
              onTap: _startNav,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: FlatButton2(
            label: t.recording ? 'FAHRT BEENDEN' : 'FAHRT STARTEN',
            color: t.recording ? amber : (_route != null ? cool : signal),
            strong: true,
            fill: _route == null && !t.recording
                ? signal
                : panel.withValues(alpha: 0.96),
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
    final lanes = nav.rerouting ? null : nav.nextLanes;
    if (lanes != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _laneRow(lanes),
      ));
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

    // Antippen wiederholt die Ansage - mit aktueller Entfernung.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Voice.instance.say(nav.repeatText(), repeat: true),
      child: Container(
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
      ),
    );
  }

  /// Spuren wie auf dem Schild: empfohlene hell, andere grau.
  Widget _laneRow(LaneInfo info) {
    IconData icon(Set<String> ind) {
      bool has(String x) => ind.contains(x);
      if (has('reverse')) return Icons.u_turn_left;
      if (has('left') || has('sharp_left')) return Icons.turn_left;
      if (has('right') || has('sharp_right')) return Icons.turn_right;
      if (has('slight_left') || has('merge_to_left')) return Icons.turn_slight_left;
      if (has('slight_right') || has('merge_to_right')) {
        return Icons.turn_slight_right;
      }
      return Icons.straight;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: asphalt,
        border: Border.all(color: line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < info.lanes.length; i++) ...[
          if (i > 0)
            Container(width: 1, height: 26, color: steel.withValues(alpha: 0.5)),
          SizedBox(
            width: 34,
            child: Icon(icon(info.lanes[i].indications),
                size: 26,
                color: info.lanes[i].recommended ? chalk : steel.withValues(alpha: 0.45)),
          ),
        ],
      ]),
    );
  }

  /// Warnung vor einer engen Kurve: Richtung, Entfernung, Richttempo.
  Widget _curveChip(RoadCurve c, double distM) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: amber,
        border: Border.all(color: Colors.black26),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(
            c.hairpin
                ? (c.right ? Icons.u_turn_right : Icons.u_turn_left)
                : (c.right ? Icons.turn_sharp_right : Icons.turn_sharp_left),
            size: 26,
            color: Colors.black),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(c.label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Colors.black)),
              Text(
                  '${distM < 20 ? 'jetzt' : _fmtDist(distM)} · '
                  'ca. ${c.adviseKmh} km/h',
                  style: const TextStyle(fontSize: 11, color: Colors.black)),
            ],
          ),
        ),
      ]),
    );
  }

  /// Tempolimit-Schild wie an der Strasse; bei zu hohem Tempo rot
  /// hinterlegt, daneben das eigene Tempo.
  Widget _limitSign(SpeedLimit l, bool speeding) {
    final sign = Container(
      width: 54,
      height: 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: speeding ? redline : Colors.white,
        shape: BoxShape.circle,
        border: Border.all(
            color: l.isUnlimited ? Colors.black54 : redline, width: 5.5),
      ),
      child: l.isUnlimited
          ? Transform.rotate(
              angle: -math.pi / 4,
              child: Container(width: 40, height: 3, color: Colors.black54),
            )
          : Text('${l.kmh}',
              style: TextStyle(
                  fontSize: l.kmh >= 100 ? 17 : 21,
                  fontWeight: FontWeight.w800,
                  color: speeding ? Colors.white : Colors.black)),
    );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      sign,
      if (speeding) ...[
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: panel.withValues(alpha: 0.94),
          child: Text('${t.speedKmh.round()}',
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800, color: redline)),
        ),
      ],
    ]);
  }

  Widget _navBottom(NavigationSession nav) {
    final stop = nav.nextStop;
    // Mit TomTom-Schluessel: Verzoegerung aus der Fahrzeitberechnung
    // mit Verkehr, sonst Summe der gemeldeten Staus.
    final delay = nav.etaWithTraffic
        ? nav.trafficEta!.delaySec
        : nav.ahead
            .where((i) => i.alongM > nav.alongM)
            .fold<int>(0, (s, i) => s + i.delaySec);
    final limit = nav.speedLimit;
    final curve = nav.curveAhead;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (_sim != null) _simBar(),
      if (kTestBuild && _hub.sessions.any((s) => s.shareLive)) _pttButton(),
      if (limit != null || curve != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            if (limit != null) _limitSign(limit, nav.speeding),
            if (limit != null && curve != null) const SizedBox(width: 8),
            if (curve != null) Flexible(child: _curveChip(curve.$1, curve.$2)),
          ]),
        ),
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
              if (nav.etaWithTraffic)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.traffic, size: 14, color: signal),
                ),
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
                      '${stop.poi.displayName} in ${_fmtDist(stop.distanceM)}'
                      '${_fuelPrices[stop.poi.id] != null ? ' · ${_fuelPrices[stop.poi.id]!.text}' : ''}',
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
            big: true,
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
            big: true,
              icon: Icons.skip_next,
              label: 'STOPP ÜBERSPR.',
              onTap: nav.skipNextStop,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: _mapBtn(
            big: true,
            icon: Icons.refresh,
            label: 'NEU',
            onTap: nav.rerouteNow,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _mapBtn(
            big: true,
            icon: Icons.ios_share,
            label: 'NAVI-APP',
            onTap: _showExport,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _mapBtn(
            big: true,
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
            strong: true,
            fill: panel.withValues(alpha: 0.96),
            tall: true,
            onTap: _holdHint,
            onLongPress: _stopNav,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FlatButton2(
            label: t.recording ? 'FAHRT BEENDEN' : 'FAHRT STARTEN',
            color: t.recording ? amber : signal,
            strong: true,
            fill: panel.withValues(alpha: 0.96),
            tall: true,
            onTap: t.recording ? _holdHint : widget.onToggleRide,
            onLongPress: widget.onToggleRide,
          ),
        ),
      ]),
    ]);
  }

  /// Kartenknopf. Waehrend der Navigation groesser ([big]) - mit
  /// Handschuhen trifft man kleine Flaechen schlecht.
  Widget _mapBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    bool big = false,
  }) {
    final c = active ? signal : chalk;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: big ? 13 : 8),
        decoration: BoxDecoration(
          color: panel.withValues(alpha: 0.94),
          border: Border.all(color: active ? signal : line),
        ),
        child: Column(children: [
          Icon(icon, size: big ? 24 : 17, color: c),
          const SizedBox(height: 3),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                  fontSize: big ? 8.5 : 8, letterSpacing: 1.2, color: c)),
        ]),
      ),
    );
  }

  /// Beenden waehrend der Fahrt nur durch Gedrueckthalten - ein
  /// versehentlicher Tipp mit dem Handschuh soll weder die Navigation
  /// noch die Aufzeichnung beenden.
  void _holdHint() => toast(context, 'Zum Beenden gedrückt halten');
}

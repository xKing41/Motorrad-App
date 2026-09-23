import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/route_plan.dart';
import 'curve_warning.dart';
import 'geo.dart';
import 'route_follow.dart';
import 'route_patch.dart';
import 'routing_engine.dart';
import 'speed_limits.dart';
import 'traffic_eta.dart';
import 'traffic_service.dart';

/// Sprachausgabe, austauschbar fuer Tests.
typedef Speak = void Function(String text);

/// Naechster Stopp auf der Route.
class NextStop {
  NextStop(this.poi, this.distanceM);
  final Poi poi;
  final double distanceM;
}

// ---------------------------------------------------------------------------
//  NAVIGATION
//
//  Was eine Navi-App unterwegs koennen muss - und was diese hier tut:
//   * Abbiegehinweise mit Entfernung, als Anzeige und als Ansage.
//   * Verfahren? Nach wenigen Sekunden neu berechnen - und zwar zurueck
//     AUF DIE TOUR, nicht einfach irgendwie zum Ziel. Sonst waere die
//     kurvige Strecke nach dem ersten Verfahren weg.
//   * Staus, Sperrungen, Baustellen voraus (mit Verkehrsdienst): melden,
//     Sperrungen automatisch umfahren, bei Staus die Umfahrung anbieten,
//     wenn sie wirklich schneller ist.
//   * Auf Zuruf: Strecke voraus sperren ("da ist dicht") oder den
//     naechsten Stopp auslassen.
// ---------------------------------------------------------------------------

class NavigationSession extends ChangeNotifier {
  NavigationSession({
    required RoutePlan plan,
    required this.engine,
    required this.prefs,
    this.traffic,
    this.limits,
    this.etaSource,
    this.speedWarning = false,
    this.curveWarning = true,
    Speak? speak,
    this.autoAvoidClosures = true,
    this.trafficEvery = const Duration(minutes: 5),
  })  : _speak = speak ?? ((_) {}),
        _plan = plan {
    _rebuild();
  }

  final RoutingEngine engine;
  final RoutingPrefs prefs;
  final TrafficFeed? traffic;

  /// Fahrzeit mit echtem Verkehr (TomTom). null = Schaetzung der Engine.
  final TomTomEta? etaSource;

  /// Letzte Fahrzeit mit Verkehr fuer den Rest der Strecke, und wo der
  /// Fahrer da war.
  TrafficEta? trafficEta;
  double _etaFromM = 0;
  bool _etaBusy = false;

  /// Tempolimits (OSM). null = keine Anzeige.
  final SpeedLimitSource? limits;

  /// Beim Ueberschreiten des Limits einmal ansagen.
  final bool speedWarning;

  /// Vor engen Kurven warnen, wenn das Tempo zu hoch ist.
  final bool curveWarning;
  final Speak _speak;
  final bool autoAvoidClosures;
  final Duration trafficEvery;

  RoutePlan _plan;
  RoutePlan get plan => _plan;

  late RouteFollower _follower;
  late List<double> _cum;
  List<double> _stepAlong = const [];
  List<(Poi, double)> _stops = const [];

  FollowState? follow;
  int _stepIdx = 0;
  final Map<int, int> _announced = {};
  // Ansage-Stufen je Abbiegung, beim ersten Blick darauf festgelegt -
  // sonst wuerden sie sich mit dem Tempo verschieben und doppelt kommen.
  final Map<int, List<double>> _stages = {};

  /// Letzte Position auf der Route (m ab Start), solange der Fahrer
  /// noch auf ihr war.
  double _onRouteAlong = 0;
  DateTime? _offSince;

  @visibleForTesting
  set debugOffSince(DateTime? v) => _offSince = v;
  @visibleForTesting
  set debugOverSince(DateTime? v) => _overSince = v;
  @visibleForTesting
  set debugNoRerouteUntil(DateTime v) => _noRerouteUntil = v;
  DateTime _noRerouteUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Fehlgeschlagene Neuberechnungen in Folge (z. B. Funkloch). Dann wird
  /// seltener versucht und nicht jedes Mal angesagt.
  int _rerouteFails = 0;
  int get rerouteFails => _rerouteFails;
  bool rerouting = false;
  bool arrived = false;

  /// Kurze Meldung fuer die Anzeige ("Neue Route: +2 km").
  String? banner;
  DateTime? _bannerUntil;

  /// Verkehrsmeldungen vor dem Fahrer (nach Entfernung sortiert).
  List<TrafficIncident> ahead = const [];

  /// Schwere Meldung, fuer die eine Umfahrung angeboten wird.
  TrafficIncident? offer;
  final Set<String> _handled = {};
  DateTime? _lastTraffic;
  bool _trafficBusy = false;
  String? trafficError;

  final Set<String> _skipped = {};

  RoutePoint? _here;
  double? _heading;
  double _speedMs = 0;

  void _rebuild() {
    // Fahrzeit mit Verkehr gehoerte zur alten Linie.
    trafficEta = null;
    _follower = RouteFollower(_plan);
    _cum = cumulativeDistances(_plan.points);
    final n = _plan.points.length;
    _stepAlong = [
      for (final s in _plan.steps) _cum[s.pointIndex.clamp(0, n - 1)],
    ];
    _stepIdx = 0;
    _announced.clear();
    _stages.clear();
    _stops = [
      for (final p in _plan.pois.where((p) => p.source == 'stop'))
        if (projectOnPolyline(RoutePoint(p.lat, p.lon), _plan.points, _cum)
            case final h?)
          (p, h.alongM),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    _loadLimits();
    _curves = curveWarning
        ? CurveFinder.find(_plan.points, skipNear: [
            for (var i = 0; i < _plan.steps.length; i++)
              if (_plan.steps[i].type != ManeuverType.start) _stepAlong[i],
          ])
        : const [];
    _curveIdx = 0;
    _curveWarned.clear();
    curveAhead = null;
    // Neue Linie: Meldungen neu zuordnen.
    ahead = [
      for (final i in ahead)
        ...TrafficService.matchToRoute([i], _plan.points, _cum),
    ];
  }

  double get totalM => _cum.isEmpty ? 0 : _cum.last;

  // ---------------------------------------------------------------------
  //  Tempolimit
  // ---------------------------------------------------------------------

  List<SpeedLimit> _limits = const [];
  List<RoutePoint>? _limitsFor;
  SpeedLimit? _warnedFor;
  DateTime? _overSince;

  /// Tempolimits der aktuellen Route (leer, solange unbekannt).
  List<SpeedLimit> get speedLimits => _limits;

  void _loadLimits() {
    final src = limits;
    if (src == null) return;
    final pts = _plan.points;
    if (identical(pts, _limitsFor)) return;
    _limitsFor = pts;
    _limits = const [];
    _warnedFor = null;
    src.forRoute(pts).then((l) {
      // Inzwischen neue Route? Dann gehoert das Ergebnis nicht mehr dazu.
      if (!identical(_plan.points, pts)) return;
      _limits = l;
      notifyListeners();
    }, onError: (_) {
      if (identical(_limitsFor, pts)) _limitsFor = null;
    });
  }

  /// Limit an der aktuellen Stelle; null, wenn unbekannt oder abseits
  /// der Route.
  SpeedLimit? get speedLimit {
    final f = follow;
    if (f == null || f.offRouteM > 40 || _limits.isEmpty) return null;
    return limitAt(_limits, alongM);
  }

  /// Toleranz wie beim Blitzer: bis 100 km/h 3 km/h, darueber 3 %.
  static double tolerance(int kmh) => kmh <= 100 ? 3 : kmh * 0.03;

  /// Faehrt der Fahrer gerade zu schnell?
  bool get speeding {
    final l = speedLimit;
    if (l == null || l.isUnlimited) return false;
    return _speedMs * 3.6 > l.kmh + tolerance(l.kmh);
  }

  void _checkSpeed() {
    final l = speedLimit;
    if (!speeding || l == null) {
      _overSince = null;
      return;
    }
    _overSince ??= DateTime.now();
    // Kurz drueber (Ueberholen, Ortsschild gerade passiert) ist noch
    // keine Warnung wert; einmal je Abschnitt reicht.
    if (speedWarning &&
        !identical(_warnedFor, l) &&
        DateTime.now().difference(_overSince!).inSeconds >= 4) {
      _warnedFor = l;
      _say('Tempolimit ${l.kmh}.');
    }
  }

  /// Aufsummierte Laengen der aktuellen Route (fuer die fluessige Anzeige).
  List<double> get routeCum => _cum;

  /// Ist der Fahrer gerade auf der Route?
  bool get onRoute => (follow?.offRouteM ?? 999) < 30;
  double get alongM => follow == null ? _onRouteAlong : totalM - follow!.remainingM;
  double get remainingM => follow?.remainingM ?? totalM;

  /// Restfahrzeit: Anteil der geplanten Zeit plus Verzug durch Staus.
  /// Stammt die Restzeit aus echten Verkehrsdaten?
  bool get etaWithTraffic {
    final e = trafficEta;
    return e != null &&
        DateTime.now().difference(e.at) < const Duration(minutes: 20) &&
        alongM >= _etaFromM - 200;
  }

  Duration get remainingTime {
    final e = trafficEta;
    if (etaWithTraffic && e != null) {
      // Seit der Abfrage gefahrene Strecke anteilig abziehen.
      final restAtCalc = math.max(1.0, totalM - _etaFromM);
      final share = (remainingM / restAtCalc).clamp(0.0, 1.0);
      return Duration(seconds: (e.travelSec * share).round());
    }
    final share = totalM > 0 ? remainingM / totalM : 0.0;
    final delay = ahead
        .where((i) => i.alongM > alongM && !_handled.contains(i.id))
        .fold<int>(0, (s, i) => s + i.delaySec);
    return Duration(seconds: (_plan.durationSec * share).round() + delay);
  }

  DateTime get eta => DateTime.now().add(remainingTime);

  RouteStep? get nextStep =>
      _stepIdx < _plan.steps.length ? _plan.steps[_stepIdx] : null;

  double get distanceToNext => distanceToNextFrom(alongM);

  /// Entfernung zur naechsten Abbiegung von einer (weitergerechneten)
  /// Position aus - fuer eine gleichmaessig laufende Anzeige.
  double distanceToNextFrom(double along) => _stepIdx < _stepAlong.length
      ? math.max(0, _stepAhead(along))
      : 0;

  double _stepAhead(double along) => _stepAlong[_stepIdx] - along;

  /// Die Anweisung danach, wenn sie gleich folgt ("dann links").
  RouteStep? get thenStep {
    final i = _stepIdx + 1;
    if (i >= _plan.steps.length) return null;
    return _stepAlong[i] - _stepAlong[_stepIdx] < 250 ? _plan.steps[i] : null;
  }

  NextStop? get nextStop {
    for (final s in _stops) {
      if (_skipped.contains(s.$1.id)) continue;
      if (s.$2 > alongM + 30) return NextStop(s.$1, s.$2 - alongM);
    }
    return null;
  }

  bool _spoke = false;

  void _say(String t) {
    _spoke = true;
    _speak(t);
  }

  /// Ansage zum Wiederholen (Antippen der Anzeige): die naechste
  /// Anweisung mit der aktuellen Entfernung.
  String repeatText() {
    if (arrived) return 'Sie haben Ihr Ziel erreicht.';
    final f = follow;
    if (f != null && f.offRouteM > 50) {
      return 'Sie sind abseits der Route. Bitte zur Route zurückkehren.';
    }
    final s = nextStep;
    if (s == null) return 'Der Route folgen.';
    final d = distanceToNext;
    final then = thenStep;
    final thenText = then != null ? ', dann ${then.alert ?? then.text}' : '';
    if (d < 60) return '${s.verbal ?? s.text}$thenText';
    if (d > 5000) {
      return 'Der Straße ${spokenDistanceNom(d)} folgen, '
          'dann ${s.alert ?? s.text}';
    }
    return 'In ${spokenDistance(d)}: ${s.alert ?? s.text}$thenText';
  }

  /// "800 Meter", "12 Kilometer" (ohne Dativ).
  static String spokenDistanceNom(double m) => spokenDistance(m)
      .replaceAll('Metern', 'Meter')
      .replaceAll('einem Kilometer', 'einen Kilometer')
      .replaceAll('Kilometern', 'Kilometer');

  // ---------------------------------------------------------------------
  //  Kurven-Vorwarnung
  // ---------------------------------------------------------------------
  List<RoadCurve> _curves = const [];
  int _curveIdx = 0;
  final Set<int> _curveWarned = {};

  /// Enge Kurve voraus, vor der gerade gewarnt wird (mit Entfernung bis
  /// zum Kurvenbeginn) - sonst null.
  (RoadCurve, double)? curveAhead;

  List<RoadCurve> get curves => _curves;

  void _checkCurves() {
    curveAhead = null;
    if (_curves.isEmpty) return;
    final along = alongM;
    while (_curveIdx < _curves.length && _curves[_curveIdx].endM < along) {
      _curveIdx++;
    }
    // Die naechsten zwei Kurven pruefen (eine harmlose kann vor einer
    // engen liegen).
    for (var k = _curveIdx; k < math.min(_curves.length, _curveIdx + 3); k++) {
      final c = _curves[k];
      final d = c.startM - along;
      if (d > 1500) break;
      // Schon in der Kurve: Anzeige bleibt bis zum Scheitel.
      final inCurve = d < 0 && along < c.apexM;
      if (inCurve && _curveWarned.contains(k)) {
        curveAhead = (c, 0);
        return;
      }
      if (!CurveFinder.shouldWarn(c, d, _speedMs)) continue;
      curveAhead = (c, d);
      if (!_curveWarned.contains(k) && !_spoke) {
        _curveWarned.add(k);
        _say(d < 80
            ? 'Achtung, ${c.label}!'
            : 'Achtung, ${c.label} in ${spokenDistance(d)}.');
      }
      return;
    }
  }

  // Stopps vorab ansagen: "In 10 Kilometern: Tankstopp, Aral."
  final Map<String, int> _stopAnnounced = {};
  static const List<double> stopStages = [10000, 1500];

  static String stopLabel(PoiKind k) => switch (k) {
        PoiKind.fuel => 'Tankstopp',
        PoiKind.food => 'Einkehr',
        PoiKind.rest => 'Pause',
        PoiKind.viewpoint => 'Aussichtspunkt',
        PoiKind.water => 'Trinkwasser',
        PoiKind.workshop => 'Werkstatt',
      };

  void _announceStops() {
    final s = nextStop;
    if (s == null) return;
    final done = _stopAnnounced[s.poi.id] ?? 0;
    var due = -1;
    for (var i = 0; i < stopStages.length; i++) {
      if (s.distanceM <= stopStages[i]) due = i;
    }
    if (due < 0 || due < done) return;
    // Nie mitten in eine Abbiege-Ansage hinein - dann beim naechsten
    // GPS-Punkt.
    if (_spoke) return;
    _stopAnnounced[s.poi.id] = due + 1;
    final name = s.poi.name?.isNotEmpty == true ? ', ${s.poi.name}' : '';
    final spoken =
        s.distanceM < stopStages[due] * 0.8 ? s.distanceM : stopStages[due];
    _say('In ${spokenDistance(spoken)}: ${stopLabel(s.poi.kind)}$name.');
  }

  void _flash(String msg, {int seconds = 8}) {
    banner = msg;
    _bannerUntil = DateTime.now().add(Duration(seconds: seconds));
  }

  /// Start der Navigation: erste Anweisung ansagen.
  void start() {
    final first = _plan.steps.isNotEmpty ? _plan.steps.first : null;
    if (first != null) _announced[0] = 2;
    _say(first?.verbal ?? first?.text ?? 'Route gestartet.');
    unawaited(checkTraffic(force: true));
  }

  /// Neue Position. [heading] in Grad, [speedMs] in m/s.
  void update(double lat, double lon, {double? heading, double speedMs = 0}) {
    _spoke = false;
    _here = RoutePoint(lat, lon);
    _heading = heading;
    _speedMs = speedMs;
    final f = _follower.update(lat, lon);
    if (f == null) return;
    follow = f;

    if (_bannerUntil != null && DateTime.now().isAfter(_bannerUntil!)) {
      banner = null;
      _bannerUntil = null;
    }

    // Abseits der Route?
    if (f.offRouteM > 50) {
      curveAhead = null;
      _offSince ??= DateTime.now();
      final long = DateTime.now().difference(_offSince!).inSeconds >= 6;
      if (long && !rerouting && speedMs > 1.5 &&
          DateTime.now().isAfter(_noRerouteUntil)) {
        unawaited(_rejoin());
      }
    } else {
      _offSince = null;
      if (f.offRouteM < 30) {
        _onRouteAlong = totalM - f.remainingM;
        _rerouteFails = 0;
      }
      _advanceSteps();
      _announceStops();
      _checkCurves();
    }

    if (!arrived && f.remainingM < 40 && f.offRouteM < 60) {
      arrived = true;
      _say('Sie haben Ihr Ziel erreicht.');
      _flash('ZIEL ERREICHT', seconds: 30);
    }

    final last = _lastTraffic;
    if (traffic != null &&
        (last == null || DateTime.now().difference(last) > _trafficInterval)) {
      unawaited(checkTraffic());
    }
    _checkIncidentWarnings();
    _checkSpeed();
    notifyListeners();
  }

  void _advanceSteps() {
    final along = alongM;
    while (_stepIdx < _stepAlong.length && _stepAlong[_stepIdx] < along - 15) {
      _stepIdx++;
    }
    // "Losfahren" ist mit dem ersten Meter erledigt.
    if (_stepIdx < _plan.steps.length &&
        _plan.steps[_stepIdx].type == ManeuverType.start &&
        along > _stepAlong[_stepIdx] + 30) {
      _stepIdx++;
    }
    final s = nextStep;
    if (s == null) return;
    final d = distanceToNext;
    final stages = _stages[_stepIdx] ?? announceStages(s.type, _speedMs);
    final done = _announced[_stepIdx] ?? 0; // Anzahl erledigter Stufen
    // Welche Stufe ist gerade dran? Die letzte, deren Entfernung schon
    // unterschritten ist. Uebersprungene Stufen (Abbiegung kam schnell
    // nach der vorigen) werden nicht nachgeholt.
    var due = -1;
    for (var i = 0; i < stages.length; i++) {
      if (d <= stages[i]) due = i;
    }
    if (due < 0 || due < done) return;
    _announced[_stepIdx] = due + 1;
    _stages[_stepIdx] = stages;
    final last = due == stages.length - 1;
    final then = thenStep;
    final thenText = then != null ? ', dann ${then.alert ?? then.text}' : '';
    if (last) {
      _say('${s.verbal ?? s.text}$thenText');
    } else {
      // Die Nenn-Entfernung der Stufe ("in 3 Kilometern") - ausser die
      // tatsaechliche liegt deutlich darunter.
      final spoken = d < stages[due] * 0.8 ? d : stages[due];
      _say('In ${spokenDistance(spoken)}: ${s.alert ?? s.text}');
    }
  }

  /// Ab welchen Entfernungen (m) eine Abbiegung angesagt wird - absteigend,
  /// die letzte ist die Ansage direkt davor.
  ///
  /// Autobahn (Ausfahrt, Auffahrt, Spurwahl oder ab 85 km/h): 3 km, 1 km,
  /// 400 m und kurz davor - wie bei den grossen Navis. Landstrasse: 1 km
  /// (ab 70 km/h), 400 m, kurz davor. Ort: 250 m und kurz davor.
  static List<double> announceStages(int type, double speedMs) {
    final v = math.max(speedMs, 5.0);
    final highwayManeuver = type == ManeuverType.rampRight ||
        type == ManeuverType.rampLeft ||
        type == ManeuverType.exitRight ||
        type == ManeuverType.exitLeft ||
        type == ManeuverType.stayLeft ||
        type == ManeuverType.stayRight ||
        type == ManeuverType.stayStraight ||
        type == ManeuverType.merge;
    // "Kurz davor": etwa 6 Sekunden, auf der Autobahn etwas mehr.
    if (v >= 23.6 || (highwayManeuver && v >= 16)) {
      return [3000, 1000, 400, math.max(150.0, v * 6)];
    }
    if (v >= 13.9) {
      return [if (v >= 19.4) 1000, 400, math.max(80.0, v * 6)];
    }
    return [250, math.max(40.0, v * 5)];
  }

  /// "800 Metern", "1,5 Kilometern" - fuer die Ansage.
  static String spokenDistance(double m) {
    if (m < 950) {
      final r = m < 300 ? (m / 50).round() * 50 : (m / 100).round() * 100;
      return '$r Metern';
    }
    final km = m / 1000;
    if (km < 10) {
      final t = (km * 2).round() / 2;
      final s = t == t.roundToDouble()
          ? t.round().toString()
          : t.toStringAsFixed(1).replaceAll('.', ',');
      return s == '1' ? 'einem Kilometer' : '$s Kilometern';
    }
    return '${km.round()} Kilometern';
  }

  // ---------------------------------------------------------------------
  //  Neu berechnen
  // ---------------------------------------------------------------------

  RoutePatcher get _patcher => RoutePatcher(engine, prefs);

  void _apply(EngineRoute r, String msg) {
    _plan = planWith(_plan, r);
    _rebuild();
    follow = null;
    final h = _here;
    if (h != null) follow = _follower.update(h.lat, h.lon);
    final f = follow;
    _onRouteAlong = f != null ? totalM - f.remainingM : 0;
    _offSince = null;
    _flash(msg);
    unawaited(_updateEta());
  }

  Future<void> _rejoin() async {
    final h = _here;
    if (h == null) return;
    rerouting = true;
    _flash('ROUTE WIRD NEU BERECHNET ...', seconds: 30);
    if (_rerouteFails == 0) _say('Route wird neu berechnet.');
    notifyListeners();
    try {
      final res = await _patcher.rejoin(engineRouteOf(_plan),
          here: h, lastAlongM: _onRouteAlong, heading: _heading);
      _rerouteFails = 0;
      _apply(res.route, 'Zurück zur Tour');
      _noRerouteUntil = DateTime.now().add(const Duration(seconds: 10));
    } on RouteException catch (e) {
      _rerouteFails++;
      // Ohne Netz bleibt die gespeicherte Route auf der Karte - der
      // Fahrer kann ihr folgen. Neuer Versuch nach 20, 40, 60 s.
      _flash('Neuberechnung nicht möglich: ${e.message} '
          'Die Route bleibt auf der Karte.', seconds: 12);
      if (_rerouteFails == 1) {
        _say('Neuberechnung nicht möglich. Bitte zur Route zurückkehren.');
      }
      _noRerouteUntil = DateTime.now()
          .add(Duration(seconds: 20 * math.min(3, _rerouteFails)));
    } finally {
      rerouting = false;
      notifyListeners();
    }
  }

  /// Sofort neu berechnen (Knopf).
  Future<void> rerouteNow() => _rejoin();

  /// Die Strecke direkt voraus meiden (Sperrung, die der Dienst nicht
  /// kennt, Baustelle, Unfall ...). Umgeplant wird ab der aktuellen
  /// Position.
  Future<bool> avoidAhead({double fromM = 50, double lengthM = 800}) async {
    final h = _here;
    if (h == null || rerouting) return false;
    final a = alongM + fromM;
    final avoid = [
      for (var d = 0.0; d <= lengthM; d += 200) pointAlong(_plan.points, _cum, a + d),
    ];
    return _detour(
      fromM: alongM,
      toM: a + lengthM + 3000,
      avoid: avoid,
      msg: 'Umleitung berechnet',
    );
  }

  /// Den naechsten Stopp auslassen.
  Future<bool> skipNextStop() async {
    final s = nextStop;
    if (s == null || rerouting) return false;
    _skipped.add(s.poi.id);
    final ok = await _detour(
      fromM: alongM,
      toM: alongM + s.distanceM + 1500,
      avoid: const [],
      msg: '${s.poi.displayName} ausgelassen',
    );
    if (!ok) _skipped.remove(s.poi.id);
    return ok;
  }

  Future<bool> _detour({
    required double fromM,
    required double toM,
    required List<RoutePoint> avoid,
    required String msg,
  }) async {
    rerouting = true;
    notifyListeners();
    try {
      final res = await _patcher.avoidSection(engineRouteOf(_plan),
          fromM: fromM, toM: toM, avoid: avoid, here: _here, heading: _heading);
      final km = res.extraM / 1000;
      _apply(res.route,
          '$msg (${km >= 0 ? '+' : ''}${km.toStringAsFixed(1).replaceAll('.', ',')} km)');
      _say('Neue Route.');
      return true;
    } on RouteException catch (e) {
      _flash('Keine Umfahrung gefunden: ${e.message}');
      return false;
    } finally {
      rerouting = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  //  Verkehrslage
  // ---------------------------------------------------------------------

  /// Wie oft die Verkehrslage geprueft wird: auf der Autobahn (ab
  /// 85 km/h) alle 2 Minuten - dort baut sich ein Stau schnell auf und man
  /// ist schnell dort -, sonst im eingestellten Takt.
  Duration get _trafficInterval => _speedMs >= 23.6
      ? const Duration(minutes: 2)
      : trafficEvery;

  /// Fragt Meldungen fuer die naechsten 150 km ab.
  /// Fahrzeit mit Verkehr fuer den Rest der Strecke neu holen.
  Future<void> _updateEta() async {
    final src = etaSource;
    if (src == null || _etaBusy) return;
    _etaBusy = true;
    final from = alongM;
    final pts = _plan.points;
    try {
      final e = await src.forRoute(pts, fromM: from);
      if (e != null && identical(pts, _plan.points)) {
        trafficEta = e;
        _etaFromM = from;
      }
    } finally {
      _etaBusy = false;
    }
  }

  Future<void> checkTraffic({bool force = false}) async {
    unawaited(_updateEta());
    final t = traffic;
    if (t == null || _trafficBusy) return;
    if (!force &&
        _lastTraffic != null &&
        DateTime.now().difference(_lastTraffic!) < _trafficInterval) {
      return;
    }
    _trafficBusy = true;
    _lastTraffic = DateTime.now();
    try {
      final list = await t.alongRoute(_plan.points,
          fromM: alongM,
          toM: alongM + 150000,
          maxBoxes: 4,
          steps: _plan.steps);
      if (list == null) {
        trafficError = 'Verkehrslage nicht abrufbar';
      } else {
        trafficError = t.lastError;
        ahead = list;
        await _reactToTraffic();
      }
    } on TrafficKeyException catch (e) {
      trafficError = e.toString();
    } finally {
      _trafficBusy = false;
      notifyListeners();
    }
  }

  Future<void> _reactToTraffic() async {
    for (final inc in ahead) {
      if (_handled.contains(inc.id) || inc.alongM < alongM) continue;
      if (!inc.isSevere) continue;
      if (inc.isClosure && autoAvoidClosures) {
        _handled.add(inc.id);
        _say('Achtung, Sperrung in ${spokenDistance(inc.alongM - alongM)}. '
            'Route wird angepasst.');
        final ok = await avoidIncident(inc, speak: false);
        if (!ok) _flash('Sperrung voraus - keine Umfahrung gefunden');
        return; // Route hat sich geaendert, Rest beim naechsten Abruf.
      }
      if (offer == null) {
        offer = inc;
        final min = (inc.delaySec / 60).round();
        _say('${inc.category.label} in ${spokenDistance(inc.alongM - alongM)}'
            '${min > 0 ? ', etwa $min Minuten Verzögerung' : ''}. '
            'Umfahrung möglich.');
      }
    }
  }

  final Set<String> _warned = {};

  /// Kurz vor einer (nicht umfahrenen) Meldung nochmal warnen.
  void _checkIncidentWarnings() {
    for (final inc in ahead) {
      final d = inc.alongM - alongM;
      if (d < 0 || d > 2000 || _warned.contains(inc.id)) continue;
      _warned.add(inc.id);
      _say('Achtung: ${inc.category.label} in ${spokenDistance(d)}.');
    }
  }

  /// Umfaehrt eine Meldung. Rueckgabe: true, wenn die Route geaendert
  /// wurde.
  Future<bool> avoidIncident(TrafficIncident inc, {bool speak = true}) async {
    _handled.add(inc.id);
    if (offer?.id == inc.id) offer = null;
    rerouting = true;
    notifyListeners();
    try {
      final res = await TrafficRerouter(_patcher).detour(
        engineRouteOf(_plan),
        inc,
        here: _here,
        hereAlongM: alongM,
        heading: _heading,
      );
      if (res == null) {
        _flash('Umfahrung wäre nicht schneller - Route bleibt.');
        return false;
      }
      final min = (res.extraSec / 60).round();
      _apply(res.route,
          '${inc.category.label} umfahren (${min >= 0 ? '+' : ''}$min min)');
      ahead = ahead.where((i) => i.id != inc.id).toList();
      if (speak) _say('Neue Route um ${inc.category.label}.');
      return true;
    } on RouteException catch (e) {
      _flash('Keine Umfahrung gefunden: ${e.message}');
      return false;
    } finally {
      rerouting = false;
      notifyListeners();
    }
  }

  /// Angebotene Umfahrung ablehnen.
  void dismissOffer() {
    final o = offer;
    if (o != null) _handled.add(o.id);
    offer = null;
    notifyListeners();
  }
}

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_plan.dart';
import '../services/ai_config.dart';
import '../services/ai_planner.dart';
import '../services/geocoder.dart';
import '../services/ride_store.dart';
import '../services/route_planner.dart';
import '../services/route_patch.dart';
import '../services/routing_engine.dart';
import '../services/routing_settings.dart';
import '../services/traffic_service.dart';
import '../theme.dart';
import 'ai_connect_screen.dart';

/// Routenplanung: entweder per Reglern oder per Freitext an die KI.
///
/// Beides landet im selben [RouteRequest] - die KI ist nur ein
/// bequemerer Weg, die gleichen Regler zu setzen. Geplant wird immer
/// aus dem, was auf dem Bildschirm steht. So sieht der Fahrer genau,
/// was die KI verstanden hat.
class RoutePlannerScreen extends StatefulWidget {
  const RoutePlannerScreen({super.key, this.startLat, this.startLon});

  final double? startLat;
  final double? startLon;

  @override
  State<RoutePlannerScreen> createState() => _RoutePlannerScreenState();
}

class _RoutePlannerScreenState extends State<RoutePlannerScreen> {
  double _distanceKm = 150;
  Curviness _curviness = Curviness.curvy;
  TourDirection _direction = TourDirection.any;
  bool _roundTrip = true;
  bool _avoidMotorways = true;
  bool _avoidUnpaved = true;
  bool _preferKnown = false;
  final Set<PoiKind> _stops = {};
  double _fuelEveryKm = 150;
  double _breakEveryKm = 100;

  /// Eigener Start statt GPS-Position (z. B. Tour am Urlaubsort planen).
  Place? _start;
  bool _pickStart = false;
  Place? _dest;
  Place? _via;

  final _aiCtrl = TextEditingController();
  bool _busy = false;
  String? _status;
  String? _aiReply;

  // Einstellungen
  RoutingSettings _routing = const RoutingSettings();
  AiConfig _ai = const AiConfig();
  final _valhallaCtrl = TextEditingController();
  final _ghUrlCtrl = TextEditingController();
  final _ghKeyCtrl = TextEditingController();
  final _tomtomCtrl = TextEditingController();
  bool _voice = true;
  RoutingService _serviceSel = RoutingService.valhalla;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _aiCtrl.dispose();
    _valhallaCtrl.dispose();
    _ghUrlCtrl.dispose();
    _ghKeyCtrl.dispose();
    _tomtomCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Einstellungen laden / speichern
  // ------------------------------------------------------------------
  Future<void> _loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    final ai = await AiConfig.load();
    final routing = await RoutingSettings.load();
    if (!mounted) return;
    setState(() {
      _ai = ai;
      _routing = routing;
      _serviceSel = routing.service;
      _valhallaCtrl.text = routing.valhallaUrl;
      _ghUrlCtrl.text = routing.ghUrl;
      _ghKeyCtrl.text = routing.ghKey;
      _tomtomCtrl.text = routing.tomtomKey;
      _voice = routing.voice;
      // Letzte eigene Vorgaben wieder herstellen.
      _distanceKm = (sp.getDouble('plan_km') ?? 150).clamp(20, 600).toDouble();
      _curviness = CurvinessX.parse(sp.getString('plan_curv') ?? 'curvy');
      _avoidMotorways = sp.getBool('plan_no_motorway') ?? true;
      _avoidUnpaved = sp.getBool('plan_no_unpaved') ?? true;
      _fuelEveryKm =
          (sp.getDouble('plan_fuel_km') ?? 150).clamp(60, 400).toDouble();
      _breakEveryKm =
          (sp.getDouble('plan_break_km') ?? 100).clamp(40, 250).toDouble();
      _stops.addAll((sp.getStringList('plan_stops') ?? const [])
          .map(PoiKindX.parse)
          .whereType<PoiKind>());
    });
  }

  Future<void> _rememberChoices() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('plan_km', _distanceKm);
    await sp.setString('plan_curv', _curviness.id);
    await sp.setBool('plan_no_motorway', _avoidMotorways);
    await sp.setBool('plan_no_unpaved', _avoidUnpaved);
    await sp.setDouble('plan_fuel_km', _fuelEveryKm);
    await sp.setDouble('plan_break_km', _breakEveryKm);
    await sp.setStringList('plan_stops', _stops.map((k) => k.id).toList());
  }

  Future<void> _saveRouting() async {
    final r = _routing.copyWith(
      service: _serviceSel,
      valhallaUrl: _valhallaCtrl.text.trim(),
      ghUrl: _ghUrlCtrl.text.trim(),
      ghKey: _ghKeyCtrl.text.trim(),
      tomtomKey: _tomtomCtrl.text.trim(),
      voice: _voice,
    );
    if (r.service == RoutingService.graphhopper && r.ghUrl.isEmpty) {
      toast(context, 'Für GraphHopper fehlt die Server-Adresse');
      return;
    }
    await r.save();
    if (!mounted) return;
    setState(() => _routing = r);
    toast(context, 'Gespeichert');
  }

  // ------------------------------------------------------------------
  // Start
  // ------------------------------------------------------------------
  double? get _startLat => _start?.lat ?? widget.startLat;
  double? get _startLon => _start?.lon ?? widget.startLon;
  bool get _hasStart => _startLat != null && _startLon != null;

  RouteRequest _buildRequest() => RouteRequest(
        startLat: _startLat!,
        startLon: _startLon!,
        roundTrip: _roundTrip,
        endLat: _roundTrip ? null : _dest?.lat,
        endLon: _roundTrip ? null : _dest?.lon,
        distanceKm: _distanceKm,
        curviness: _curviness,
        direction: _direction,
        viaLat: _via?.lat,
        viaLon: _via?.lon,
        avoidMotorways: _avoidMotorways,
        avoidUnpaved: _avoidUnpaved,
        preferKnownGoodRoads: _preferKnown,
        stops: _stops.map((k) => StopWish(kind: k, repeat: true)).toList(),
        destinationName: _dest?.name,
        fuelEveryKm: _fuelEveryKm,
        breakEveryKm: _breakEveryKm,
      );

  // ------------------------------------------------------------------
  // Planen
  // ------------------------------------------------------------------
  Future<void> _plan({
    String? aiText,
    List<StopWish>? aiStops,
    String? title,
  }) async {
    if (!_hasStart) {
      setState(() => _status = 'Kein Standort bekannt. Bitte unten einen '
          'Start suchen oder auf GPS warten.');
      return;
    }
    if (!_roundTrip && _dest == null) {
      setState(() => _status = 'Bitte ein Ziel suchen und auswählen - '
          'oder auf RUNDTOUR umschalten.');
      return;
    }
    if (!_routing.isUsable) {
      setState(() => _status = 'Routing-Dienst unvollständig eingerichtet. '
          'Unter EINSTELLUNGEN prüfen.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Route wird berechnet ...';
    });
    await _rememberChoices();

    try {
      var req = _buildRequest().copyWith(title: title);
      // KI-Stopps behalten ihre Begruendung und Kilometerangabe.
      if (aiStops != null) req = req.copyWith(stops: aiStops);

      Map<String, double>? heatmap;
      if (_preferKnown) {
        setState(() => _status = 'Eigene Fahrten werden ausgewertet ...');
        heatmap = await RideStore.instance.buildLeanHeatmap();
      }

      final engine = _routing.engine();
      final planner = TourPlanner(engine, heatmap: heatmap);
      var plan = await planner.plan(req, onProgress: (m) {
        if (mounted) setState(() => _status = m);
      });

      // Staus und Sperrungen gleich beim Planen umfahren.
      if (_routing.hasTraffic) {
        plan = await TrafficPlanCheck.apply(
          plan,
          TrafficService(_routing.tomtomKey),
          RoutePatcher(engine, RoutingPrefs.of(req)),
          say: (m) {
            if (mounted) setState(() => _status = m);
          },
        );
      }

      if (_preferKnown && (heatmap == null || heatmap.isEmpty)) {
        plan = plan.copyWith(notes: [
          ...plan.notes,
          'Noch keine eigenen Fahrten gespeichert - '
              '"Bewährte Strecken" hatte keine Wirkung.',
        ]);
      }

      // Optional: Beschreibungstext von der KI, nur aus echten Fakten.
      if (aiText != null && _ai.isConfigured) {
        if (!mounted) return;
        setState(() => _status = 'Beschreibung wird erstellt ...');
        final desc =
            await _ai.planner().describe(plan: plan, userText: aiText);
        if (desc != null) plan = plan.copyWith(description: desc);
      }

      if (!mounted) return;
      Navigator.pop(context, plan);
    } on RouteException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Route konnte nicht berechnet werden.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Oeffnet die Einrichtung und uebernimmt das Ergebnis.
  Future<void> _openConnect() async {
    final res = await Navigator.push<AiConfig>(
      context,
      MaterialPageRoute(builder: (_) => AiConnectScreen(config: _ai)),
    );
    if (!mounted || res == null) return;
    setState(() => _ai = res);
  }

  Future<void> _planWithAi() async {
    final text = _aiCtrl.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();

    if (!_ai.isConfigured) {
      await _openConnect();
      if (!mounted || !_ai.isConfigured) return;
    }
    if (!_hasStart) {
      setState(() => _status = 'Kein Standort bekannt. Bitte auf GPS warten '
          'oder unten einen Start suchen.');
      return;
    }

    setState(() {
      _busy = true;
      _aiReply = null;
      _status = 'KI liest den Wunsch ...';
    });

    try {
      final res = await _ai.planner().interpret(
            userText: text,
            startLat: _startLat!,
            startLon: _startLon!,
          );
      final r = res.request;

      // Ortsnamen der KI in echten Kartendaten suchen.
      Place? dest;
      Place? via;
      if (r.destinationName != null) {
        setState(() => _status = 'Ziel "${r.destinationName}" wird gesucht ...');
        final found = await Geocoder.search(r.destinationName!,
            nearLat: _startLat, nearLon: _startLon, limit: 1);
        if (found.isEmpty) {
          if (mounted) {
            setState(() => _status = 'Ziel "${r.destinationName}" nicht '
                'gefunden. Bitte unten von Hand suchen.');
          }
          return;
        }
        dest = found.first;
      }
      if (r.towardsName != null) {
        setState(() => _status = '"${r.towardsName}" wird gesucht ...');
        final found = await Geocoder.search(r.towardsName!,
            nearLat: _startLat, nearLon: _startLon, limit: 1);
        if (found.isNotEmpty) via = found.first;
      }

      if (!mounted) return;
      // Regler mitziehen, damit sichtbar wird, was die KI verstanden hat.
      setState(() {
        _distanceKm = r.distanceKm.clamp(20, 600).toDouble();
        _curviness = r.curviness;
        _roundTrip = r.roundTrip;
        _direction = r.direction;
        _avoidMotorways = r.avoidMotorways;
        _avoidUnpaved = r.avoidUnpaved;
        _preferKnown = r.preferKnownGoodRoads;
        _dest = dest ?? (r.roundTrip ? null : _dest);
        _via = via;
        _stops
          ..clear()
          ..addAll(r.stops.map((s) => s.kind));
        _aiReply = [
          res.reply,
          res.safetyNote,
          if (r.towardsName != null && via == null)
            '"${r.towardsName}" wurde nicht gefunden - Richtung frei gewählt.',
        ].whereType<String>().where((s) => s.isNotEmpty).join('\n');
      });

      await _plan(aiText: text, aiStops: r.stops, title: r.title);
    } on AiException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Die KI-Planung ist fehlgeschlagen. '
            'Bitte erneut versuchen oder die Regler nutzen.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------
  // Aufbau
  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ROUTE PLANEN')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _aiBox(),
          const SizedBox(height: 18),
          _sectionTitle('ODER SELBST EINSTELLEN'),
          const SizedBox(height: 10),
          _modeRow(),
          const SizedBox(height: 12),
          _startRow(),
          const SizedBox(height: 14),
          if (_roundTrip) ...[
            _distanceRow(),
            const SizedBox(height: 12),
            _directionRow(),
            const SizedBox(height: 14),
            _PlaceField(
              label: 'ÜBER (OPTIONAL)',
              hint: 'Ort oder Gegend, z. B. Edersee',
              value: _via,
              nearLat: _startLat,
              nearLon: _startLon,
              onChanged: (p) => setState(() => _via = p),
            ),
          ] else ...[
            _PlaceField(
              label: 'ZIEL',
              hint: 'Ort, Adresse oder Sehenswürdigkeit',
              value: _dest,
              nearLat: _startLat,
              nearLon: _startLon,
              onChanged: (p) => setState(() => _dest = p),
            ),
            const SizedBox(height: 10),
            _PlaceField(
              label: 'ÜBER (OPTIONAL)',
              hint: 'Zwischenziel',
              value: _via,
              nearLat: _startLat,
              nearLon: _startLon,
              onChanged: (p) => setState(() => _via = p),
            ),
          ],
          const SizedBox(height: 14),
          _curvinessRow(),
          const SizedBox(height: 10),
          _switchRow('Autobahnen meiden', _avoidMotorways,
              (v) => setState(() => _avoidMotorways = v)),
          _switchRow('Schotter und Feldwege meiden', _avoidUnpaved,
              (v) => setState(() => _avoidUnpaved = v)),
          _switchRow('Meine bewährten Strecken bevorzugen', _preferKnown,
              (v) => setState(() => _preferKnown = v)),
          const SizedBox(height: 14),
          _sectionTitle('ZWISCHENSTOPPS'),
          const SizedBox(height: 8),
          _stopChips(),
          if (_stops.contains(PoiKind.fuel))
            _intervalRow(
              'TANKEN SPÄTESTENS ALLE',
              _fuelEveryKm,
              60,
              400,
              (v) => setState(() => _fuelEveryKm = v),
              amber,
            ),
          if (_stops.contains(PoiKind.rest) ||
              _stops.contains(PoiKind.food) ||
              _stops.contains(PoiKind.water))
            _intervalRow(
              'PAUSE ETWA ALLE',
              _breakEveryKm,
              40,
              250,
              (v) => setState(() => _breakEveryKm = v),
              cool,
            ),
          if (_stops.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Stopps werden über die ganze Strecke verteilt: Tanken nach '
                'Reichweite, Pausen im gewählten Abstand (Rastplatz und '
                'Einkehr im Wechsel), Aussichtspunkte gleichmäßig.',
                style: TextStyle(fontSize: 9.5, color: steel, height: 1.4),
              ),
            ),
          const SizedBox(height: 20),
          if (_status != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: panel,
                border: Border.all(color: line),
              ),
              child: Row(children: [
                if (_busy) ...[
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        color: amber, strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(_status!,
                      style: const TextStyle(fontSize: 11, color: amber)),
                ),
              ]),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: FlatButton2(
              label: _busy ? 'BITTE WARTEN ...' : 'ROUTE BERECHNEN',
              color: signal,
              strong: true,
              onTap: _busy ? null : () => _plan(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Routing: ${_routing.engine().label}',
            style: const TextStyle(fontSize: 9, color: steel),
          ),
          const SizedBox(height: 22),
          _settingsBox(),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Text(
        s,
        style: const TextStyle(fontSize: 9.5, letterSpacing: 3, color: steel),
      );

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Color color = signal,
    EdgeInsets padding =
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : panel,
          border: Border.all(color: selected ? color : line),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1,
            color: selected ? color : chalk,
          ),
        ),
      ),
    );
  }

  Widget _modeRow() {
    return Row(children: [
      Expanded(
        child: _chip(
          label: 'RUNDTOUR',
          selected: _roundTrip,
          onTap: () => setState(() => _roundTrip = true),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _chip(
          label: 'VON A NACH B',
          selected: !_roundTrip,
          onTap: () => setState(() => _roundTrip = false),
        ),
      ),
    ]);
  }

  Widget _startRow() {
    final gps = widget.startLat != null && widget.startLon != null;
    if (gps && !_pickStart && _start == null) {
      return Row(children: [
        const Icon(Icons.my_location, size: 14, color: cool),
        const SizedBox(width: 8),
        const Expanded(
          child: Text('Start: aktueller Standort',
              style: TextStyle(fontSize: 11.5, color: chalk)),
        ),
        InkWell(
          onTap: () => setState(() => _pickStart = true),
          child: const Padding(
            padding: EdgeInsets.all(4),
            child: Text('ANDERER START',
                style: TextStyle(fontSize: 9, letterSpacing: 1.5, color: steel)),
          ),
        ),
      ]);
    }
    // Kein GPS oder bewusst anderer Start: suchen lassen.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!gps && _start == null)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              'Noch kein GPS-Standort. Start suchen oder kurz warten.',
              style: TextStyle(fontSize: 10.5, color: amber),
            ),
          ),
        _PlaceField(
          label: 'START',
          hint: 'Ort oder Adresse',
          value: _start,
          nearLat: widget.startLat,
          nearLon: widget.startLon,
          onChanged: (p) => setState(() => _start = p),
        ),
        if (gps)
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: () => setState(() {
                _start = null;
                _pickStart = false;
              }),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Text('AKTUELLEN STANDORT NEHMEN',
                    style: TextStyle(
                        fontSize: 9, letterSpacing: 1.5, color: steel)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _aiBox() {
    final ready = _ai.isConfigured;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: panel,
        border: Border(
          left: BorderSide(color: ready ? signal : steel, width: 3),
          top: const BorderSide(color: line),
          right: const BorderSide(color: line),
          bottom: const BorderSide(color: line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.auto_awesome, size: 14, color: ready ? signal : steel),
            const SizedBox(width: 6),
            const TinyLabel('TOUR BESCHREIBEN'),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _aiCtrl,
            maxLines: 3,
            minLines: 2,
            style: const TextStyle(fontSize: 12.5, color: chalk),
            decoration: _inputDecoration(
              'z. B. "Nachmittagsrunde, gut 180 km, viele Kurven, über den '
              'Edersee, einmal tanken und eine Pause mit Aussicht"',
            ),
          ),
          if (_aiReply != null && _aiReply!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_aiReply!,
                style: const TextStyle(fontSize: 11, color: cool, height: 1.4)),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FlatButton2(
              label: ready ? 'MIT KI PLANEN' : 'KI VERBINDEN',
              color: ready ? signal : steel,
              onTap: _busy ? null : (ready ? _planWithAi : _openConnect),
            ),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _busy ? null : _openConnect,
            child: Row(children: [
              Icon(ready ? Icons.link : Icons.link_off,
                  size: 12, color: ready ? cool : steel),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  ready ? 'KI: ${_ai.label}' : 'KI: nicht verbunden',
                  style: TextStyle(fontSize: 9.5, color: ready ? cool : steel),
                ),
              ),
              const Text('ÄNDERN',
                  style: TextStyle(
                      fontSize: 9, letterSpacing: 1.5, color: steel)),
            ]),
          ),
          const SizedBox(height: 6),
          const Text(
            'Die KI setzt nur die Vorgaben. Strecke und Orte kommen aus '
            'echten Kartendaten – erfundene Ziele sind so ausgeschlossen.',
            style: TextStyle(fontSize: 9.5, color: steel, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _distanceRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const TinyLabel('LÄNGE'),
          const Spacer(),
          Text('${_distanceKm.round()} km',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: chalk)),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: signal,
            inactiveTrackColor: line,
            thumbColor: signal,
            overlayColor: signal.withValues(alpha: 0.15),
            trackHeight: 3,
          ),
          child: Slider(
            value: _distanceKm,
            min: 20,
            max: 600,
            divisions: 58,
            onChanged: (v) => setState(() => _distanceKm = v),
          ),
        ),
      ],
    );
  }

  Widget _directionRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TinyLabel('RICHTUNG'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: TourDirection.values
              .map((d) => _chip(
                    label: d.label,
                    selected: d == _direction,
                    color: cool,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    onTap: () => setState(() => _direction = d),
                  ))
              .toList(),
        ),
        if (_via != null)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Mit einem "Über"-Ort bestimmt dieser die Richtung.',
                style: TextStyle(fontSize: 9.5, color: steel)),
          ),
      ],
    );
  }

  Widget _curvinessRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TinyLabel('KURVIGKEIT'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: Curviness.values
              .map((c) => _chip(
                    label: c.label,
                    selected: c == _curviness,
                    onTap: () => setState(() => _curviness = c),
                  ))
              .toList(),
        ),
      ],
    );
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(fontSize: 11.5, color: chalk)),
        ),
        Switch(value: value, onChanged: onChanged),
      ]),
    );
  }

  Widget _intervalRow(String label, double value, double min, double max,
      ValueChanged<double> onChanged, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            TinyLabel(label),
            const Spacer(),
            Text('${value.round()} km',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          ]),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: color,
              inactiveTrackColor: line,
              thumbColor: color,
              overlayColor: color.withValues(alpha: 0.15),
              trackHeight: 3,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: ((max - min) / 10).round(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stopChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: PoiKind.values.map((k) {
        final sel = _stops.contains(k);
        return _chip(
          label: k.label,
          selected: sel,
          color: cool,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          onTap: () => setState(() {
            if (sel) {
              _stops.remove(k);
            } else {
              _stops.add(k);
            }
          }),
        );
      }).toList(),
    );
  }

  Widget _settingsBox() {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      iconColor: steel,
      collapsedIconColor: steel,
      title: const Text('EINSTELLUNGEN',
          style: TextStyle(fontSize: 9.5, letterSpacing: 3, color: steel)),
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: TinyLabel('ROUTING-DIENST'),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: _chip(
              label: 'VALHALLA',
              selected: _serviceSel == RoutingService.valhalla,
              onTap: () =>
                  setState(() => _serviceSel = RoutingService.valhalla),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _chip(
              label: 'GRAPHHOPPER',
              selected: _serviceSel == RoutingService.graphhopper,
              onTap: () =>
                  setState(() => _serviceSel = RoutingService.graphhopper),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (_serviceSel == RoutingService.valhalla) ...[
          const Text(
            'Kostenlos und ohne Schlüssel, mit eigenem Motorrad-Profil. '
            'Standard ist der öffentliche Server der FOSSGIS '
            '(OpenStreetMap). Bitte fair nutzen.',
            style: TextStyle(fontSize: 10, color: steel, height: 1.4),
          ),
          const SizedBox(height: 8),
          _field(
            label: 'EIGENER VALHALLA-SERVER (leer = öffentlich)',
            controller: _valhallaCtrl,
            hint: ValhallaEngine.publicUrl,
          ),
        ] else ...[
          _field(
            label: 'GRAPHHOPPER-ADRESSE',
            controller: _ghUrlCtrl,
            hint: 'https://graphhopper.com/api/1',
          ),
          _field(
            label: 'GRAPHHOPPER-SCHLÜSSEL',
            controller: _ghKeyCtrl,
            hint: 'nur bei der offiziellen API nötig',
            obscure: true,
          ),
        ],
        const SizedBox(height: 6),
        const Align(
          alignment: Alignment.centerLeft,
          child: TinyLabel('VERKEHRSLAGE (STAUS, SPERRUNGEN)'),
        ),
        const SizedBox(height: 6),
        const Text(
          'Aktuelle Staus, Sperrungen und Baustellen gibt es nicht frei '
          'und ohne Schlüssel. Mit einem kostenlosen TomTom-Schlüssel '
          '(developer.tomtom.com, 2.500 Abfragen am Tag) werden sie beim '
          'Planen und während der Fahrt umfahren.',
          style: TextStyle(fontSize: 10, color: steel, height: 1.4),
        ),
        const SizedBox(height: 8),
        _field(
          label: 'TOMTOM-SCHLÜSSEL (leer = ohne Verkehrslage)',
          controller: _tomtomCtrl,
          hint: 'API-Key',
          obscure: true,
        ),
        _switchRow('Sprachansagen bei der Navigation', _voice,
            (v) => setState(() => _voice = v)),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: FlatButton2(
            label: 'EINSTELLUNGEN SPEICHERN',
            onTap: _saveRouting,
          ),
        ),
        const SizedBox(height: 10),
        // Der KI-Zugang hat seinen eigenen Bildschirm - dort gibt es
        // auch einen echten Verbindungstest.
        SizedBox(
          width: double.infinity,
          child: FlatButton2(
            label: 'KI-ANBINDUNG EINRICHTEN',
            onTap: _openConnect,
          ),
        ),
      ],
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TinyLabel(label),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            obscureText: obscure,
            autocorrect: false,
            style: const TextStyle(fontSize: 12, color: chalk),
            decoration: _inputDecoration(hint, dense: true),
          ),
        ],
      ),
    );
  }
}

InputDecoration _inputDecoration(String? hint, {bool dense = false}) =>
    InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 11, color: steel),
      isDense: dense,
      filled: true,
      fillColor: asphalt,
      contentPadding: const EdgeInsets.all(10),
      border: const OutlineInputBorder(
        borderSide: BorderSide(color: line),
        borderRadius: BorderRadius.zero,
      ),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: line),
        borderRadius: BorderRadius.zero,
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: signal),
        borderRadius: BorderRadius.zero,
      ),
    );

/// Ortssuche mit Ergebnisliste. Gesucht wird nur auf Knopfdruck.
class _PlaceField extends StatefulWidget {
  const _PlaceField({
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
    this.nearLat,
    this.nearLon,
  });

  final String label;
  final String hint;
  final Place? value;
  final ValueChanged<Place?> onChanged;
  final double? nearLat;
  final double? nearLon;

  @override
  State<_PlaceField> createState() => _PlaceFieldState();
}

class _PlaceFieldState extends State<_PlaceField> {
  final _ctrl = TextEditingController();
  List<Place> _results = const [];
  bool _busy = false;
  String? _msg;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _msg = null;
    });
    final r = await Geocoder.search(q,
        nearLat: widget.nearLat, nearLon: widget.nearLon);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _results = r;
      _msg = r.isEmpty ? 'Nichts gefunden (oder kein Internet).' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    if (v != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TinyLabel(widget.label),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(
              color: panel,
              border: Border.all(color: cool),
            ),
            child: Row(children: [
              const Icon(Icons.place, size: 15, color: cool),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(v.name,
                        style: const TextStyle(fontSize: 12, color: chalk)),
                    if (v.detail.isNotEmpty)
                      Text(v.detail,
                          style: const TextStyle(fontSize: 9.5, color: steel)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 16, color: steel),
                onPressed: () => widget.onChanged(null),
              ),
            ]),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TinyLabel(widget.label),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              style: const TextStyle(fontSize: 12, color: chalk),
              decoration: _inputDecoration(widget.hint, dense: true),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 40,
            child: FlatButton2(
              label: _busy ? '...' : 'SUCHEN',
              onTap: _busy ? null : _search,
            ),
          ),
        ]),
        if (_msg != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_msg!,
                style: const TextStyle(fontSize: 10, color: amber)),
          ),
        for (final p in _results)
          InkWell(
            onTap: () {
              setState(() => _results = const []);
              widget.onChanged(p);
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: line),
                  right: BorderSide(color: line),
                  bottom: BorderSide(color: line),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      style: const TextStyle(fontSize: 11.5, color: chalk)),
                  if (p.detail.isNotEmpty)
                    Text(p.detail,
                        style: const TextStyle(fontSize: 9.5, color: steel)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

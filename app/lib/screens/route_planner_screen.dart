import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/route_plan.dart';
import '../services/ai_config.dart';
import '../services/ai_planner.dart';
import 'ai_connect_screen.dart';
import '../services/route_planner.dart';
import '../theme.dart';

/// Routenplanung: entweder per Reglern oder per Freitext an die KI.
///
/// Beides landet im selben [RouteRequest] - die KI ist nur ein
/// bequemerer Weg, die gleichen Parameter zu setzen.
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
  bool _roundTrip = true;
  bool _avoidMotorways = true;
  bool _preferKnown = false;
  final Set<PoiKind> _stops = {};

  final _aiCtrl = TextEditingController();
  bool _busy = false;
  String? _status;
  String? _aiReply;

  // Einstellungen
  String _ghUrl = '';
  String _ghKey = '';
  AiConfig _ai = const AiConfig();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _aiCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    final ai = await AiConfig.load();
    if (!mounted) return;
    setState(() {
      _ghUrl = sp.getString('gh_url') ?? '';
      _ghKey = sp.getString('gh_key') ?? '';
      _ai = ai;
    });
  }

  Future<void> _saveSettings() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('gh_url', _ghUrl);
    await sp.setString('gh_key', _ghKey);
  }

  RoutePlanner _engine() {
    if (_ghUrl.trim().isEmpty) return DemoLoopPlanner();
    return GraphHopperPlanner(
      baseUrl: _ghUrl.trim(),
      apiKey: _ghKey.trim().isEmpty ? null : _ghKey.trim(),
    );
  }

  RouteRequest _buildRequest() => RouteRequest(
        startLat: widget.startLat ?? 51.1657,
        startLon: widget.startLon ?? 10.4515,
        roundTrip: _roundTrip,
        distanceKm: _distanceKm,
        curviness: _curviness,
        avoidMotorways: _avoidMotorways,
        preferKnownGoodRoads: _preferKnown,
        stops: _stops.map((k) => StopWish(kind: k)).toList(),
      );

  // ------------------------------------------------------------------
  // Planen
  // ------------------------------------------------------------------
  Future<void> _plan(RouteRequest req, {String? aiText}) async {
    setState(() {
      _busy = true;
      _status = 'Route wird berechnet ...';
    });

    try {
      var plan = await _engine().plan(req);

      if (req.stops.isNotEmpty) {
        if (!mounted) return;
        setState(() => _status = 'Stopps werden gesucht ...');
        plan = await StopResolver.attachStops(plan, req.stops);
      }

      // Optional: Beschreibungstext von der KI, nur aus echten Fakten
      if (aiText != null && _ai.isConfigured) {
        if (!mounted) return;
        setState(() => _status = 'Beschreibung wird erstellt ...');
        final desc =
            await _ai.planner().describe(plan: plan, userText: aiText);
        if (desc != null) {
          plan = RoutePlan(
            points: plan.points,
            distanceM: plan.distanceM,
            durationSec: plan.durationSec,
            steps: plan.steps,
            pois: plan.pois,
            title: plan.title,
            description: desc,
          );
        }
      }

      if (!mounted) return;
      Navigator.pop(context, plan);
    } on RouteException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } catch (_) {
      if (mounted) setState(() => _status = 'Route konnte nicht berechnet werden.');
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

    // Nicht verbunden? Dann direkt die Einrichtung oeffnen, statt den
    // Nutzer in den Einstellungen suchen zu lassen.
    if (!_ai.isConfigured) {
      await _openConnect();
      if (!mounted || !_ai.isConfigured) return;
    }

    setState(() {
      _busy = true;
      _aiReply = null;
      _status = 'KI liest den Wunsch ...';
    });

    try {
      final ai = _ai.planner();
      final res = await ai.interpret(
        userText: text,
        startLat: widget.startLat ?? 51.1657,
        startLon: widget.startLon ?? 10.4515,
      );

      // Regler mitziehen, damit sichtbar wird, was die KI verstanden hat
      setState(() {
        _distanceKm = res.request.distanceKm.clamp(20, 600);
        _curviness = res.request.curviness;
        _roundTrip = res.request.roundTrip;
        _avoidMotorways = res.request.avoidMotorways;
        _stops
          ..clear()
          ..addAll(res.request.stops.map((s) => s.kind));
        _aiReply = [res.reply, res.safetyNote]
            .where((s) => s != null && s.isNotEmpty)
            .join('\n');
      });

      await _plan(res.request, aiText: text);
    } on AiException catch (e) {
      if (mounted) setState(() => _status = e.message);
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
          // Ohne Routing-Server kann die App keine Strassen kennen. Das muss
          // man VOR dem Planen sehen, nicht erst an der Karte.
          if (_ghUrl.trim().isEmpty) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: panel,
                border: const Border(
                    left: BorderSide(color: amber, width: 3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('DEMO-MODUS – KEIN ROUTING-SERVER',
                      style: TextStyle(
                          fontSize: 10, letterSpacing: 1.5, color: amber)),
                  const SizedBox(height: 5),
                  const Text(
                    'Ohne Routing-Server zeichnet die App nur eine Testschleife, '
                    'die keinen echten Straßen folgt. Unter EINSTELLUNGEN einen '
                    'Server eintragen, dann kommen echte Routen.',
                    style: TextStyle(fontSize: 10.5, color: steel, height: 1.45),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          _aiBox(),
          const SizedBox(height: 18),
          _sectionTitle('ODER SELBST EINSTELLEN'),
          const SizedBox(height: 10),
          _distanceRow(),
          const SizedBox(height: 14),
          _curvinessRow(),
          const SizedBox(height: 14),
          _switchRow('Rundtour (zurück zum Start)', _roundTrip,
              (v) => setState(() => _roundTrip = v)),
          _switchRow('Autobahnen meiden', _avoidMotorways,
              (v) => setState(() => _avoidMotorways = v)),
          _switchRow('Meine bewährten Strecken bevorzugen', _preferKnown,
              (v) => setState(() => _preferKnown = v)),
          const SizedBox(height: 14),
          _sectionTitle('ZWISCHENSTOPPS'),
          const SizedBox(height: 8),
          _stopChips(),
          const SizedBox(height: 20),
          if (_status != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: panel,
                border: Border.all(color: line),
              ),
              child: Text(_status!,
                  style: const TextStyle(fontSize: 11, color: amber)),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: FlatButton2(
              label: _busy ? 'BITTE WARTEN ...' : 'ROUTE BERECHNEN',
              color: signal,
              strong: true,
              onTap: _busy ? null : () => _plan(_buildRequest()),
            ),
          ),
          const SizedBox(height: 26),
          _settingsBox(),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Text(
        s,
        style: const TextStyle(fontSize: 9.5, letterSpacing: 3, color: steel),
      );

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
            decoration: InputDecoration(
              hintText: 'z. B. "Nachmittagsrunde, gut 180 km, viele Kurven, '
                  'einmal tanken und eine Pause mit Aussicht"',
              hintStyle: const TextStyle(fontSize: 11.5, color: steel),
              filled: true,
              fillColor: asphalt,
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
              contentPadding: const EdgeInsets.all(10),
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
                  style: TextStyle(
                      fontSize: 9.5, color: ready ? cool : steel),
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

  Widget _curvinessRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TinyLabel('KURVIGKEIT'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: Curviness.values.map((c) {
            final sel = c == _curviness;
            return GestureDetector(
              onTap: () => setState(() => _curviness = c),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: sel ? signal.withValues(alpha: 0.14) : panel,
                  border: Border.all(color: sel ? signal : line),
                ),
                child: Text(
                  c.label,
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1,
                    color: sel ? signal : chalk,
                  ),
                ),
              ),
            );
          }).toList(),
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

  Widget _stopChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: PoiKind.values.map((k) {
        final sel = _stops.contains(k);
        return GestureDetector(
          onTap: () => setState(() {
            if (sel) {
              _stops.remove(k);
            } else {
              _stops.add(k);
            }
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: sel ? cool.withValues(alpha: 0.14) : panel,
              border: Border.all(color: sel ? cool : line),
            ),
            child: Text(
              k.label,
              style: TextStyle(fontSize: 10.5, color: sel ? cool : chalk),
            ),
          ),
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
        _field(
          label: 'ROUTING-SERVER (leer = Demo-Modus)',
          value: _ghUrl,
          hint: 'https://graphhopper.com/api/1',
          onChanged: (v) => _ghUrl = v,
        ),
        _field(
          label: 'ROUTING-SCHLÜSSEL',
          value: _ghKey,
          hint: 'nur bei offizieller API nötig',
          obscure: true,
          onChanged: (v) => _ghKey = v,
        ),
        // Der KI-Zugang hat seinen eigenen Bildschirm - dort gibt es
        // auch einen echten Verbindungstest.
        SizedBox(
          width: double.infinity,
          child: FlatButton2(
            label: 'KI-ANBINDUNG EINRICHTEN',
            onTap: _openConnect,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FlatButton2(
            label: 'EINSTELLUNGEN SPEICHERN',
            onTap: () async {
              await _saveSettings();
              if (mounted) {
                setState(() {});
                toast(context, 'Gespeichert');
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _field({
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
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
          TextFormField(
            initialValue: value,
            obscureText: obscure,
            style: const TextStyle(fontSize: 12, color: chalk),
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(fontSize: 11, color: steel),
              isDense: true,
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
            ),
          ),
        ],
      ),
    );
  }
}

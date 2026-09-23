
import 'package:flutter/material.dart';

import '../services/telemetry.dart';
import '../services/emergency.dart';
import '../services/power.dart';
import '../services/weather_service.dart';
import '../theme.dart';
import 'bike_screen.dart';
import 'emergency_screen.dart';
import '../widgets/gauge.dart';

/// Live-Cockpit: Schraeglage, Tempo, G-Kraefte, laufende Fahrt.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.onToggleRide});

  final VoidCallback onToggleRide;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final t = Telemetry.instance;

  @override
  void initState() {
    super.initState();
    t.addListener(_update);
  }

  @override
  void dispose() {
    t.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
        child: LayoutBuilder(builder: (context, c) {
          final landscape = c.maxWidth > c.maxHeight;
          if (landscape) {
            return Column(children: [
              _header(),
              _weatherStrip(),
              Expanded(
                child: Row(children: [
                  Expanded(
                    flex: 5,
                    child: LeanGauge(
                        lean: t.lean, maxL: t.maxLeanL, maxR: t.maxLeanR),
                  ),
                  const SizedBox(width: 14),
                  Expanded(flex: 4, child: _panel(compact: true)),
                ]),
              ),
            ]);
          }
          return Column(children: [
            _header(),
            _weatherStrip(),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: c.maxHeight * 0.34),
              child: LeanGauge(
                  lean: t.lean, maxL: t.maxLeanL, maxR: t.maxLeanR),
            ),
            Expanded(child: _panel(compact: false)),
          ]);
        }),
      ),
    );
  }

  Widget _header() {
    final String txt;
    final Color col;
    if (t.gpsDenied) {
      txt = 'GPS AUS';
      col = amber;
    } else if (t.gpsServiceOff || !t.hasFix) {
      txt = 'KEIN GPS';
      col = steel;
    } else {
      txt = t.gpsReference ? 'GPS+GYRO' : 'GPS';
      col = signal;
    }

    // Titel links, Statusfeld und Notfalltaste rechts beieinander.
    // Vorher verteilte spaceBetween den Platz auch um den Abstandhalter,
    // und das GPS-Feld stand verloren in der Mitte.
    return Row(
      children: [
        RichText(
          text: const TextSpan(
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
              color: chalk,
              fontFamily: 'monospace',
            ),
            children: [
              TextSpan(text: 'SCHRÄG'),
              TextSpan(text: 'LAGE', style: TextStyle(color: signal)),
            ],
          ),
        ),
        const Spacer(),
        InkWell(
          onTap: (t.gpsDenied || t.gpsServiceOff || !t.hasFix)
              ? () async {
                  final msg = await t.retryGps();
                  if (msg != null && mounted) toast(context, msg);
                }
              : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration:
                BoxDecoration(color: panel, border: Border.all(color: line)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(color: col, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(txt,
                  style: const TextStyle(
                      fontSize: 10, letterSpacing: 2, color: chalk)),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        // Motorrad, Reifen und Halterung - bestimmt die Messgenauigkeit.
        InkWell(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const BikeScreen())),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration:
                BoxDecoration(color: panel, border: Border.all(color: line)),
            child: const Icon(Icons.two_wheeler, size: 16, color: steel),
          ),
        ),
        const SizedBox(width: 8),
        // Zugang zu den Notfalldaten. Rot, wenn noch kein Kontakt
        // hinterlegt ist - dann bringt die Sturzerkennung nichts.
        InkWell(
          onTap: () async {
            await Navigator.push(context,
                MaterialPageRoute(builder: (_) => const EmergencyScreen()));
            if (mounted) setState(() {});
          },
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: panel,
              border: Border.all(
                  color: Emergency.instance.hasContact ? line : redline),
            ),
            child: Icon(Icons.emergency_outlined,
                size: 16,
                color:
                    Emergency.instance.hasContact ? steel : redline),
          ),
        ),
      ],
    );
  }

  /// Wetterstreifen samt Regenwarnung.
  ///
  /// Fuer Motorradfahrer die wichtigste Vorhersage ueberhaupt: nicht wie
  /// warm es wird, sondern wann es nass wird.
  Widget _weatherStrip() {
    final w = t.weather;
    if (w == null) return const SizedBox.shrink();
    final temp = w.tempC == null ? '--' : w.tempC!.round().toString();
    final windPart =
        w.windKmh == null ? '' : '   ·   ${w.windKmh!.round()} km/h Wind';
    final info = '$temp°C   ·   ${w.condition}$windPart';
    final warn = w.warning;
    final col = warn == null
        ? steel
        : (w.rainSoon || w.frostRisk ? redline : amber);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: panel,
        border: Border(
          left: BorderSide(color: col, width: 3),
          top: const BorderSide(color: line),
          right: const BorderSide(color: line),
          bottom: const BorderSide(color: line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(w.rainSoon ? Icons.umbrella : Icons.thermostat,
                size: 13, color: col),
            const SizedBox(width: 7),
            Expanded(
              child: Text(info,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: chalk)),
            ),
            if (warn != null) const SizedBox(width: 8),
            if (warn != null)
              Text(warn,
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w700,
                      color: col)),
          ]),
          const SizedBox(height: 3),
          const Text(WeatherService.attribution,
              style: TextStyle(fontSize: 8, color: steel)),
        ],
      ),
    );
  }

  /// Grosse Gradzahl samt Richtung. Haengt am schnellen Kanal, damit sich
  /// nur dieser kleine Bereich neu aufbaut und nicht das ganze Cockpit.
  Widget _leanReadout(double hero) {
    return ValueListenableBuilder<double>(
      valueListenable: t.lean,
      builder: (context, roll, _) {
        final abs = roll.abs();
        final numColor = abs >= 48 ? redline : (abs >= 35 ? amber : chalk);
        final dirTxt =
            abs < 2 ? 'AUFRECHT' : (roll < 0 ? 'LINKS' : 'RECHTS');
        return Column(children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${abs.round()}',
                  style: TextStyle(
                    fontSize: hero,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: numColor,
                  )),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('°',
                    style: TextStyle(
                        fontSize: hero * 0.45,
                        fontWeight: FontWeight.w600,
                        color: steel)),
              ),
            ],
          ),
          Text(dirTxt,
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 4,
                  color: abs < 2 ? steel : chalk)),
        ]);
      },
    );
  }

  Widget _panel({required bool compact}) {
    final kmh = t.hasFix ? t.speedKmh.round().toString() : '--';
    final hero = compact ? 46.0 : 58.0;

    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(children: [
        SizedBox(height: compact ? 4 : 8),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _leanReadout(hero)),
              Container(width: 1, color: line),
              Expanded(
                child: Column(children: [
                  Text(kmh,
                      style: TextStyle(
                        fontSize: hero,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: chalk,
                      )),
                  const Text('KM/H',
                      style: TextStyle(
                          fontSize: 10, letterSpacing: 4, color: steel)),
                ]),
              ),
            ],
          ),
        ),
        SizedBox(height: compact ? 8 : 12),
        Row(children: [
          Expanded(
              child: StatCard(
                  label: 'MAX LINKS',
                  value: '${t.maxLeanL.round()}',
                  unit: '°')),
          const SizedBox(width: 8),
          Expanded(
              child: StatCard(
                  label: 'MAX RECHTS',
                  value: '${t.maxLeanR.round()}',
                  unit: '°')),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: StatCard(
              label: 'BREMS-G',
              value: t.maxBrakeG.toStringAsFixed(2),
              sub: 'jetzt ${(-t.longG).clamp(0.0, 9.0).toStringAsFixed(2)}',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: StatCard(
              label: 'KURVEN-G',
              value: t.maxLatG.toStringAsFixed(2),
              sub: 'jetzt ${t.latG.toStringAsFixed(2)}',
            ),
          ),
        ]),
        const SizedBox(height: 8),
        _tripBar(),
        SizedBox(height: compact ? 8 : 10),
        SizedBox(
          width: double.infinity,
          child: FlatButton2(
            label: t.recording ? 'FAHRT BEENDEN' : 'FAHRT STARTEN',
            color: t.recording ? amber : signal,
            strong: true,
            tall: true,
            // Beenden nur durch Gedrueckthalten: ein Tipp mit dem
            // Handschuh soll die Fahrt nicht teilen.
            onTap: t.recording
                ? () => toast(context, 'Zum Beenden gedrückt halten')
                : widget.onToggleRide,
            onLongPress: widget.onToggleRide,
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FlatButton2(
              label: 'NULLPUNKT SETZEN',
              onTap: () {
                toast(
                    context,
                    t.calibrate()
                        ? 'Nullpunkt gesetzt - Motorrad dabei gerade halten'
                        : 'Handy wackelt - im Stand erneut versuchen');
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FlatButton2(
              label: 'MAX ZURÜCKSETZEN',
              onTap: () {
                t.resetMax();
                toast(context, 'Max-Werte zurückgesetzt');
              },
            ),
          ),
        ]),
        const SizedBox(height: 4),
        _screenToggle(),
        SizedBox(height: compact ? 4 : 8),
        const Text('NÄHERUNGSWERTE · BEDIENUNG NUR IM STAND',
            style: TextStyle(fontSize: 8.5, letterSpacing: 2, color: steel)),
      ]),
    );
  }

  /// Bildschirm waehrend der Fahrt an oder aus. Aus spart viel Akku - die
  /// Aufzeichnung und die Sturzerkennung laufen trotzdem weiter.
  Widget _screenToggle() {
    final p = PowerPolicy.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: p.screenOnWhileRiding,
      builder: (context, on, _) => InkWell(
        onTap: () => p.setScreenOnWhileRiding(!on),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(on ? Icons.light_mode : Icons.battery_saver,
                size: 15, color: on ? signal : amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                on
                    ? 'Display bleibt während der Fahrt an'
                    : 'Akku sparen: Display geht während der Fahrt aus '
                        '(Aufzeichnung läuft weiter)',
                style: const TextStyle(fontSize: 10.5, color: steel),
              ),
            ),
            Switch(value: on, onChanged: p.setScreenOnWhileRiding),
          ]),
        ),
      ),
    );
  }

  Widget _tripBar() {
    final dur = t.rideDurationSec;
    final distKm = t.rideDistanceM / 1000;
    // Durchschnitt in Fahrt, ohne Stillstand.
    final mov = t.rideMovingSec;
    final avg = (t.recording && mov > 10) ? distKm / (mov / 3600) : 0.0;

    final parts = <String>[
      'STRECKE ${distKm.toStringAsFixed(1)} KM',
      if (t.recording) 'ZEIT ${fmtDur(dur)}',
      if (t.recording && avg > 0) 'Ø ${avg.round()}',
      'VMAX ${(t.rideMaxSpeedMs * 3.6).round()}',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
      decoration: BoxDecoration(
        color: panel,
        border: Border(
          left: BorderSide(color: t.recording ? signal : line, width: 3),
          top: const BorderSide(color: line),
          right: const BorderSide(color: line),
          bottom: const BorderSide(color: line),
        ),
      ),
      child: Text(
        t.recording
            ? parts.join('   ·   ')
            : (t.rideDistanceM > 0
                ? 'LETZTE: ${parts.join('   ·   ')}'
                : 'KEINE AKTIVE FAHRT'),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 1.2,
          color: t.recording ? chalk : steel,
        ),
      ),
    );
  }
}

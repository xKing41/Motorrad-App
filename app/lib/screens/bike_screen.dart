import 'package:flutter/material.dart';

import '../services/dynamics.dart';
import '../services/telemetry.dart';
import '../theme.dart';

/// Motorrad und Halterung: alles, was die Messgenauigkeit bestimmt.
class BikeScreen extends StatefulWidget {
  const BikeScreen({super.key});

  @override
  State<BikeScreen> createState() => _BikeScreenState();
}

class _BikeScreenState extends State<BikeScreen> {
  final t = Telemetry.instance;
  late BikeProfile _bike = t.bike;

  @override
  void initState() {
    super.initState();
    t.addListener(_tick);
  }

  @override
  void dispose() {
    t.removeListener(_tick);
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _set(BikeProfile b) async {
    setState(() => _bike = b);
    await t.saveBike(b);
  }

  Widget _chips<T>(List<T> values, T selected, String Function(T) label,
      ValueChanged<T> onTap) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final v in values)
          InkWell(
            onTap: () => onTap(v),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: v == selected ? panel : asphalt,
                border: Border.all(color: v == selected ? signal : line),
              ),
              child: Text(label(v),
                  style: TextStyle(
                      fontSize: 11,
                      color: v == selected ? chalk : steel)),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final vib = t.vibrationG;
    final vibText = !t.recording && t.speedKmh < 10
        ? 'wird während der Fahrt gemessen'
        : vib < 0.15
            ? 'ruhig (${vib.toStringAsFixed(2)} g)'
            : vib < 0.35
                ? 'mittel (${vib.toStringAsFixed(2)} g)'
                : 'stark (${vib.toStringAsFixed(2)} g) - Halterung prüfen';
    final corr40 = _bike.bikeLeanDeg(40) - 40;

    return Scaffold(
      appBar: AppBar(title: const Text('MOTORRAD & HALTERUNG')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const TinyLabel('BAUART'),
          const SizedBox(height: 8),
          _chips<BikeType>(BikeType.values, _bike.type, (b) => b.label,
              (b) => _set(_bike.copyWith(type: b))),
          const SizedBox(height: 16),
          const TinyLabel('REIFENBREITE VORNE (mm)'),
          const SizedBox(height: 8),
          _chips<int>(const [90, 100, 110, 120, 130], _bike.frontWidthMm,
              (w) => '$w', (w) => _set(_bike.copyWith(frontWidthMm: w))),
          const SizedBox(height: 16),
          const TinyLabel('REIFENBREITE HINTEN (mm)'),
          const SizedBox(height: 8),
          _chips<int>(const [110, 130, 140, 150, 160, 170, 180, 190, 200],
              _bike.rearWidthMm, (w) => '$w',
              (w) => _set(_bike.copyWith(rearWidthMm: w))),
          const SizedBox(height: 10),
          Text(
            'Steht auf der Reifenflanke, z. B. 180/55 ZR17 = 180 mm. Damit '
            'rechnet die App aus, wie viel tiefer das Motorrad liegt als die '
            'Linie Reifen–Schwerpunkt: bei 40° gerade '
            '+${corr40.toStringAsFixed(1).replaceAll('.', ',')}°.',
            style: const TextStyle(fontSize: 10.5, color: steel, height: 1.45),
          ),
          const SizedBox(height: 22),
          const TinyLabel('MESSQUALITÄT'),
          const SizedBox(height: 8),
          _row('Nullpunkt der Lage', t.calibrated ? 'gesetzt' : 'noch nicht gesetzt'),
          _row('Gyroskop-Drift',
              t.gyroBiasKnown ? 'gemessen (an jeder Ampel neu)' : 'wird beim ersten Halt gemessen'),
          _row('Vibration der Halterung', vibText),
          _row('GPS', t.hasFix ? '±${t.gpsAccuracyM.round()} m' : 'kein Signal'),
          const SizedBox(height: 22),
          const TinyLabel('SO MISST DAS HANDY AM BESTEN'),
          const SizedBox(height: 8),
          const _Tip(
            icon: Icons.check_circle_outline,
            color: signal,
            text: 'Fest am Rahmen, Tank oder an der Gabelbrücke montieren. '
                'Je näher am Schwerpunkt und je steifer, desto genauer.',
          ),
          const _Tip(
            icon: Icons.warning_amber,
            color: amber,
            text: 'Am Lenker dreht sich das Handy mit jeder Lenkbewegung mit '
                'und vibriert stärker - das kostet Genauigkeit. Eine '
                'Halterung mit Vibrationsdämpfer hilft (schützt auch die '
                'Kamera des Handys).',
          ),
          const _Tip(
            icon: Icons.check_circle_outline,
            color: signal,
            text: 'Nullpunkt setzen: am montierten Handy, Motorrad gerade '
                'hinstellen (Hauptständer oder festhalten, NICHT '
                'Seitenständer). Hochkant, quer oder flach ist egal.',
          ),
          const _Tip(
            icon: Icons.info_outline,
            color: cool,
            text: 'Handys messen die Lage auf etwa 2-4 Grad genau. Das '
                'eingebaute Kurven-ABS moderner Motorräder schafft 1-2 Grad, '
                'weil es fest verbaut ist und die echte Raddrehzahl kennt.',
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
              child: Text(k, style: const TextStyle(fontSize: 11.5, color: steel))),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11.5, color: chalk)),
          ),
        ]),
      );
}

class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 11, color: chalk, height: 1.45)),
          ),
        ]),
      );
}

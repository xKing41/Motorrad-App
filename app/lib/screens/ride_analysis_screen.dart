import 'package:flutter/material.dart';

import '../models/ride.dart';
import '../services/ride_analysis.dart';
import '../theme.dart';
import '../widgets/analysis_charts.dart';

/// Tiefenauswertung einer gefahrenen Tour.
///
/// Beantwortet die Frage, die eine Navi-App nicht beantwortet: nicht
/// "wo bin ich gefahren", sondern "wie bin ich gefahren".
class RideAnalysisScreen extends StatefulWidget {
  const RideAnalysisScreen({
    super.key,
    required this.ride,
    required this.track,
  });

  final RideSummary ride;
  final List<TrackPoint> track;

  @override
  State<RideAnalysisScreen> createState() => _RideAnalysisScreenState();
}

class _RideAnalysisScreenState extends State<RideAnalysisScreen> {
  RideAnalysis? _a;

  @override
  void initState() {
    super.initState();
    // Die Auswertung laeuft ueber den gesamten Track. Bei langen Touren
    // sind das einige Tausend Punkte, deshalb erst nach dem ersten Bild,
    // damit der Bildschirm sofort erscheint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final a = RideAnalysis.of(widget.track);
      if (mounted) setState(() => _a = a);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AUSWERTUNG'),
      ),
      body: a == null
          ? const Center(child: CircularProgressIndicator(color: signal))
          : a.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Für diese Fahrt liegen zu wenige Daten vor.\n\n'
                      'Für eine Auswertung braucht es eine Aufzeichnung mit '
                      'Kurven – auf der Autobahn gibt es nichts zu bewerten.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: steel, height: 1.6),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _scoreBox(a),
                    const SizedBox(height: 18),
                    _sectionTitle('ZEIT JE SCHRÄGLAGE'),
                    const SizedBox(height: 4),
                    const Text(
                      'Sagt mehr als ein Spitzenwert: Ein einzelner Ausreißer '
                      'ist etwas anderes als eine halbe Stunde am Anschlag.',
                      style:
                          TextStyle(fontSize: 10.5, color: steel, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    LeanHistogramChart(histogram: a.histogram),
                    const SizedBox(height: 6),
                    _histoFacts(a),
                    const SizedBox(height: 20),
                    _sectionTitle('KAMMSCHER KREIS'),
                    const SizedBox(height: 4),
                    const Text(
                      'Der Reifen kann nur eine bestimmte Gesamtkraft '
                      'übertragen. Bremsen und Kurve teilen sich dieses '
                      'Budget. Punkte weit außen heißen: wenig Reserve.',
                      style:
                          TextStyle(fontSize: 10.5, color: steel, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    KammCircleChart(
                      points: a.kamm,
                      maxG: a.maxCombinedG < 1.2 ? 1.2 : a.maxCombinedG + 0.1,
                    ),
                    const SizedBox(height: 20),
                    _sectionTitle('KURVEN'),
                    const SizedBox(height: 10),
                    _cornerStats(a),
                    const SizedBox(height: 10),
                    ..._topCorners(a),
                    const SizedBox(height: 24),
                    const Text(
                      'Alle Werte sind Näherungen aus Sensor- und '
                      'GPS-Daten. Radien und Beschleunigungen werden '
                      'gerechnet, nicht gemessen.',
                      style: TextStyle(fontSize: 9.5, color: steel, height: 1.5),
                    ),
                  ],
                ),
    );
  }

  // -----------------------------------------------------------------
  Widget _scoreBox(RideAnalysis a) {
    final s = a.score;
    final col = s.total >= 70 ? cool : (s.total >= 50 ? amber : redline);

    return Container(
      padding: const EdgeInsets.all(14),
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
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${s.total.round()}',
                style: TextStyle(
                    fontSize: 46,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: col)),
            const Padding(
              padding: EdgeInsets.only(bottom: 6, left: 2),
              child: Text('/100',
                  style: TextStyle(fontSize: 14, color: steel)),
            ),
            const Spacer(),
            Text(s.grade,
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                    color: col)),
          ]),
          const SizedBox(height: 12),
          _bar('GLEICHMÄSSIGKEIT', s.smoothness,
              'Wie ruhig die Schräglage aufgebaut wurde'),
          const SizedBox(height: 8),
          _bar('BREMSDISZIPLIN', s.brakeDiscipline,
              'Wie selten in Schräglage gebremst wurde'),
          const SizedBox(height: 8),
          _bar('BALANCE LINKS/RECHTS', s.balance,
              a.leanBalanceDeg < 3
                  ? 'Beide Seiten gleich sicher'
                  : '${a.leanBalanceDeg.round()}° Unterschied zur schwächeren Seite'),
          const SizedBox(height: 12),
          const Text(
            'Mehr Schräglage gibt hier absichtlich keine Punkte. Bewertet '
            'wird, was gute Fahrer ausmacht – nicht, wer am tiefsten legt.',
            style: TextStyle(fontSize: 9.5, color: steel, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _bar(String label, double v, String hint) {
    final col = v >= 70 ? cool : (v >= 50 ? amber : redline);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: TinyLabel(label)),
          Text('${v.round()}',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: col)),
        ]),
        const SizedBox(height: 4),
        Stack(children: [
          Container(height: 5, color: asphalt),
          FractionallySizedBox(
            widthFactor: (v / 100).clamp(0.0, 1.0),
            child: Container(height: 5, color: col),
          ),
        ]),
        const SizedBox(height: 3),
        Text(hint, style: const TextStyle(fontSize: 9.5, color: steel)),
      ],
    );
  }

  Widget _histoFacts(RideAnalysis a) {
    final over35 = (a.histogram.shareAbove(35) * 100).round();
    final total = a.histogram.totalSeconds;
    return Text(
      'Aufgezeichnet: ${_dur(total.round())}   ·   '
      'davon $over35 % ab 35°   ·   '
      'höchster Summenvektor ${a.maxCombinedG.toStringAsFixed(2)} g',
      style: const TextStyle(fontSize: 10, color: steel),
    );
  }

  Widget _cornerStats(RideAnalysis a) {
    final r = a.tightestRadiusM;
    return Row(children: [
      Expanded(
        child: StatCard(
            label: 'KURVEN', value: '${a.corners.length}', unit: ''),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: StatCard(
          label: 'JE KILOMETER',
          value: a.curvesPerKm.toStringAsFixed(1),
          unit: '',
          accent: cool,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: StatCard(
          label: 'ENGSTER RADIUS',
          value: r > 0 ? r.round().toString() : '–',
          unit: r > 0 ? 'm' : '',
          accent: amber,
        ),
      ),
    ]);
  }

  List<Widget> _topCorners(RideAnalysis a) {
    // Die staerksten Kurven zuerst - danach schaut man zuerst.
    final sorted = List<Corner>.of(a.corners)
      ..sort((x, y) => y.maxLean.compareTo(x.maxLean));
    final top = sorted.take(8).toList();

    return [
      const TinyLabel('DIE STÄRKSTEN KURVEN DIESER TOUR'),
      const SizedBox(height: 8),
      for (final c in top) ...[
        _cornerRow(c),
        const SizedBox(height: 6),
      ],
    ];
  }

  Widget _cornerRow(Corner c) {
    final r = RideAnalysis.radiusOf(c);
    final col = c.maxLean >= 45 ? redline : (c.maxLean >= 35 ? amber : cool);
    final radiusPart = r > 0 ? '   ·   R ≈ ${r.round()} m' : '';
    final speeds = '${c.entrySpeedKmh.round()} → ${c.minSpeedKmh.round()}'
        ' → ${c.exitSpeedKmh.round()} km/h';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: panel,
        border: Border(
          left: BorderSide(color: col, width: 3),
          top: const BorderSide(color: line),
          right: const BorderSide(color: line),
          bottom: const BorderSide(color: line),
        ),
      ),
      child: Row(children: [
        Icon(c.direction < 0 ? Icons.turn_left : Icons.turn_right,
            size: 16, color: col),
        const SizedBox(width: 10),
        Text('${c.maxLean.round()}°',
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, color: chalk)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '$speeds$radiusPart',
            style: const TextStyle(fontSize: 10.5, color: steel),
          ),
        ),
      ]),
    );
  }

  Widget _sectionTitle(String s) => Text(s,
      style: const TextStyle(
          fontSize: 11,
          letterSpacing: 2.5,
          fontWeight: FontWeight.w700,
          color: chalk));

  String _dur(int sec) {
    if (sec >= 3600) {
      final h = sec ~/ 3600;
      final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
      return '$h:$m h';
    }
    return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')} min';
  }
}

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ride.dart';
import '../services/ride_store.dart';
import '../services/rider_profile.dart';
import '../theme.dart';

/// Persoenliche Kurvenanalyse ueber die letzten Fahrten.
class RiderProfileScreen extends StatefulWidget {
  const RiderProfileScreen({super.key});

  @override
  State<RiderProfileScreen> createState() => _RiderProfileScreenState();
}

class _RiderProfileScreenState extends State<RiderProfileScreen> {
  RiderProfile? _p;
  List<HomeCorner> _home = const [];

  /// So viele Fahrten werden ausgewertet (die neuesten).
  static const int maxRides = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = RideStore.instance;
    final rides = (await store.listRides()).take(maxRides).toList();
    final input = <RideCorners>[];
    for (final r in rides) {
      final track = await store.loadTrack(r.id);
      input.add(RideCorners(r, detectCorners(track)));
      // Zwischendurch Luft fuer die Anzeige lassen.
      await Future<void>.delayed(Duration.zero);
    }
    final p = RiderProfile.of(input);
    final home = RiderProfile.homeCorners(input);
    if (mounted) {
      setState(() {
        _p = p;
        _home = home;
      });
    }
  }

  static String _deg(CornerStats? s) =>
      s == null || s.count < 3 ? '–' : '${s.avgLean.round()}°';
  static String _g(CornerStats? s) => s == null || s.count < 3
      ? '–'
      : s.avgLatG.toStringAsFixed(2).replaceAll('.', ',');
  static String _kmh(CornerStats? s) =>
      s == null || s.count < 3 ? '–' : '${s.avgApexKmh.round()}';
  static String _n(CornerStats? s) => '${s?.count ?? 0}';

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      appBar: AppBar(title: const Text('MEIN FAHRSTIL')),
      body: p == null
          ? const Center(child: CircularProgressIndicator(color: signal))
          : p.corners < 10
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Noch zu wenige Kurven für eine Auswertung. Nach ein '
                    'paar kurvigen Fahrten steht hier, wie du links und '
                    'rechts, in engen und weiten Kurven fährst - und wo '
                    'noch Luft ist.',
                    style: TextStyle(fontSize: 12, color: steel, height: 1.5),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                        '${p.corners} Kurven aus ${p.rides} '
                        '${p.rides == 1 ? 'Fahrt' : 'Fahrten'}',
                        style: const TextStyle(fontSize: 11, color: steel)),
                    const SizedBox(height: 12),
                    const TinyLabel('HINWEISE'),
                    const SizedBox(height: 6),
                    if (p.insights.isEmpty)
                      const Text(
                          'Für Hinweise braucht es mehr Kurven je Richtung '
                          'und Kurvenart.',
                          style: TextStyle(fontSize: 11.5, color: steel)),
                    for (final i in p.insights)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: panel, border: Border.all(color: line)),
                        child: Text(i,
                            style: const TextStyle(
                                fontSize: 12, color: chalk, height: 1.45)),
                      ),
                    const SizedBox(height: 12),
                    const TinyLabel('LINKS / RECHTS NACH KURVENART'),
                    const SizedBox(height: 6),
                    _table(p),
                    const SizedBox(height: 16),
                    if (_home.isNotEmpty) ...[
                      const TinyLabel('DEINE HAUSKURVEN'),
                      const SizedBox(height: 4),
                      const Text(
                        'Kurven, die du in mindestens drei Fahrten gefahren '
                        'bist. Deine eigene Bestenliste - ohne Stoppuhr.',
                        style: TextStyle(fontSize: 10, color: steel),
                      ),
                      const SizedBox(height: 6),
                      for (final h in _home) _homeTile(h),
                      const SizedBox(height: 16),
                    ],
                    if (p.trend.length >= 3) ...[
                      const TinyLabel('MITTLERE SCHRÄGLAGE JE FAHRT'),
                      const SizedBox(height: 6),
                      SizedBox(height: 90, child: _Trend(p.trend)),
                    ],
                    const SizedBox(height: 16),
                    const Text(
                      'Ausgewertet werden Kurven ab 12° Schräglage. '
                      'Querbeschleunigung gemessen, bei älteren Fahrten aus '
                      'der Schräglage berechnet. Keine Rangliste: '
                      'Gleichmäßigkeit zählt, nicht Tempo.',
                      style: TextStyle(fontSize: 10, color: steel, height: 1.5),
                    ),
                  ],
                ),
    );
  }

  Widget _homeTile(HomeCorner h) {
    final delta = h.last - h.first;
    final trend = delta.abs() < 1.5
        ? 'gleichbleibend'
        : (delta > 0 ? '+${delta.round()}° seit dem ersten Mal'
            : '${delta.round()}° seit dem ersten Mal');
    return InkWell(
      onTap: () => launchUrl(
        Uri.parse('https://www.openstreetmap.org/?mlat=${h.lat.toStringAsFixed(5)}'
            '&mlon=${h.lon.toStringAsFixed(5)}#map=17/'
            '${h.lat.toStringAsFixed(5)}/${h.lon.toStringAsFixed(5)}'),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration:
            BoxDecoration(color: panel, border: Border.all(color: line)),
        child: Row(children: [
          Icon(h.right ? Icons.turn_right : Icons.turn_left,
              size: 20, color: signal),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${h.right ? 'Rechtskurve' : 'Linkskurve'} · '
                    '${h.count}× gefahren',
                    style: const TextStyle(fontSize: 12, color: chalk)),
                Text(
                    'Beste ${h.best.round()}° · zuletzt ${h.last.round()}° · '
                    '$trend · Streuung ±${h.spread.round()}°',
                    style: const TextStyle(fontSize: 10, color: steel)),
              ],
            ),
          ),
          const Icon(Icons.map_outlined, size: 16, color: steel),
        ]),
      ),
    );
  }

  Widget _table(RiderProfile p) {
    const h = TextStyle(fontSize: 9, letterSpacing: 1, color: steel);
    const v = TextStyle(fontSize: 12, color: chalk);
    TableRow row(String label, CornerStats? l, CornerStats? r) => TableRow(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(label, style: const TextStyle(fontSize: 11, color: chalk)),
            ),
            Text('${_deg(l)} / ${_deg(r)}', style: v),
            Text('${_g(l)} / ${_g(r)}', style: v),
            Text('${_kmh(l)} / ${_kmh(r)}', style: v),
            Text('${_n(l)} / ${_n(r)}', style: v),
          ],
        );
    return Table(
      columnWidths: const {0: FlexColumnWidth(1.6)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        const TableRow(children: [
          Text('KURVE', style: h),
          Text('LAGE L/R', style: h),
          Text('G L/R', style: h),
          Text('KM/H L/R', style: h),
          Text('ANZAHL', style: h),
        ]),
        row('Alle', p.left, p.right),
        for (final k in RadiusClass.values)
          row(k.label, p.byClass[k]!.$1, p.byClass[k]!.$2),
      ],
    );
  }
}

class _Trend extends StatelessWidget {
  const _Trend(this.points);
  final List<(DateTime, double)> points;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _TrendPainter(points), size: Size.infinite);
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.points);
  final List<(DateTime, double)> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final vals = points.map((p) => p.$2).toList();
    final lo = vals.reduce((a, b) => a < b ? a : b) - 2;
    final hi = vals.reduce((a, b) => a > b ? a : b) + 2;
    Offset at(int i) => Offset(
          size.width * i / (vals.length - 1),
          size.height * (1 - (vals[i] - lo) / (hi - lo)),
        );
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < vals.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = signal
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    final dot = Paint()..color = signal;
    for (var i = 0; i < vals.length; i++) {
      canvas.drawCircle(at(i), 2.5, dot);
    }
    final tp = TextPainter(
      text: TextSpan(
          text: '${hi.round() - 2}° max · ${lo.round() + 2}° min',
          style: const TextStyle(fontSize: 9, color: steel)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, const Offset(0, 0));
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.points != points;
}

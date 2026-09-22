import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/ride_analysis.dart';
import '../theme.dart';

// ---------------------------------------------------------------------------
// Beide Diagramme sind reine Momentaufnahmen einer abgeschlossenen Fahrt.
// Sie aendern sich nach dem Aufbau nicht mehr, deshalb shouldRepaint nur
// beim tatsaechlichen Datenwechsel.
// ---------------------------------------------------------------------------

/// Wie viel Zeit in welcher Schraeglage verbracht wurde.
///
/// Sagt mehr aus als ein Maximalwert: Ein einzelner Ausreisser auf 45 Grad
/// ist etwas anderes als eine halbe Stunde bei 30 Grad.
class LeanHistogramChart extends StatelessWidget {
  const LeanHistogramChart({super.key, required this.histogram});

  final LeanHistogram histogram;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: CustomPaint(painter: _HistogramPainter(histogram)),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.h);

  final LeanHistogram h;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 4.0;
    const bottomPad = 18.0;
    final peak = h.peakSeconds;
    if (peak <= 0) {
      _text(canvas, 'Keine Schräglagendaten', Offset(size.width / 2, size.height / 2),
          size.width * 0.035, steel, center: true);
      return;
    }

    final chartH = size.height - bottomPad;
    final n = h.bucketSeconds.length;
    final slot = (size.width - leftPad * 2) / n;
    final barW = slot * 0.66;

    for (var i = 0; i < n; i++) {
      final v = h.bucketSeconds[i];
      final lower = LeanHistogram.lowerBound(i);
      final barH = (v / peak) * (chartH - 6);
      final x = leftPad + i * slot + (slot - barW) / 2;

      // Farbe nach Warnzone, damit man sofort sieht, wo es eng wird.
      final c = lower >= 45
          ? redline
          : (lower >= 35 ? amber : (lower >= 20 ? cool : steel));

      canvas.drawRect(
        Rect.fromLTWH(x, chartH - barH, barW, barH),
        Paint()..color = c.withValues(alpha: v > 0 ? 0.9 : 0.15),
      );

      // Beschriftung nur bei jedem zweiten Balken, sonst wird es voll.
      if (i % 2 == 0) {
        _text(canvas, '${lower.round()}',
            Offset(x + barW / 2, chartH + 5), size.width * 0.026, steel,
            center: true);
      }
    }

    // Grundlinie
    canvas.drawLine(
      Offset(leftPad, chartH),
      Offset(size.width - leftPad, chartH),
      Paint()
        ..color = line
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => old.h != h;
}

/// Kammscher Kreis: Laengs- gegen Querbeschleunigung.
///
/// Der Reifen kann nur eine bestimmte Gesamtkraft uebertragen. Bremsen und
/// Kurve teilen sich dieses Budget. Punkte weit aussen bedeuten: Es war
/// wenig Reserve uebrig. Genau die Darstellung fehlt den grossen
/// Navi-Apps.
class KammCircleChart extends StatelessWidget {
  const KammCircleChart({super.key, required this.points, this.maxG = 1.2});

  final List<KammPoint> points;
  final double maxG;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AspectRatio(
        aspectRatio: 1,
        child: CustomPaint(painter: _KammPainter(points, maxG)),
      ),
    );
  }
}

class _KammPainter extends CustomPainter {
  _KammPainter(this.pts, this.maxG);

  final List<KammPoint> pts;
  final double maxG;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 14;
    final scale = r / maxG;

    // Hilfskreise bei 0,4 / 0,8 / 1,2 g
    for (final g in [0.4, 0.8, 1.2]) {
      if (g > maxG) continue;
      canvas.drawCircle(
        c,
        g * scale,
        Paint()
          ..color = (g >= 1.2 ? redline : line).withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      _text(canvas, '${g.toStringAsFixed(1)}g',
          Offset(c.dx + g * scale - 2, c.dy - 9), size.width * 0.032, steel);
    }

    // Achsen
    final axis = Paint()
      ..color = line
      ..strokeWidth = 1;
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), axis);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), axis);

    _text(canvas, 'BESCHLEUNIGEN', Offset(c.dx, c.dy - r - 10),
        size.width * 0.03, steel, center: true);
    _text(canvas, 'BREMSEN', Offset(c.dx, c.dy + r + 2), size.width * 0.03,
        steel, center: true);
    _text(canvas, 'QUER', Offset(c.dx + r - 16, c.dy + 4), size.width * 0.03,
        steel);

    // Messpunkte. Nur die Querachse nach rechts, weil der Betrag
    // gespeichert wird - Links- und Rechtskurve landen uebereinander.
    for (final p in pts) {
      final x = c.dx + p.latG * scale;
      final y = c.dy - p.longG * scale;
      final t = p.total;
      final col = t >= 1.1 ? redline : (t >= 0.8 ? amber : cool);
      canvas.drawCircle(
        Offset(x, y),
        1.6,
        Paint()..color = col.withValues(alpha: 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_KammPainter old) =>
      old.pts != pts || old.maxG != maxG;
}

// ---------------------------------------------------------------------------
void _text(Canvas canvas, String s, Offset at, double size, Color color,
    {bool center = false}) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontSize: size.clamp(7.0, 13.0),
        color: color,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset(center ? at.dx - tp.width / 2 : at.dx, at.dy));
}

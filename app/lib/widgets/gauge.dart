import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme.dart';

// ---------------------------------------------------------------------------
//  WARUM ZWEI EBENEN?
//
//  Skala, Striche und Gradzahlen aendern sich nie. Vorher wurden sie
//  trotzdem bei JEDEM Bild komplett neu gezeichnet - samt neun
//  TextPainter-Umbruechen pro Bild. Das hat die Anzeige ausgebremst.
//
//  Jetzt liegt der unveraenderliche Teil in einer eigenen Ebene mit
//  shouldRepaint = false. Sie wird nur einmal gezeichnet und danach nur
//  noch, wenn sich die Groesse aendert. Pro Bild bewegt sich lediglich
//  die obere Ebene mit Zeiger und Motorrad.
//
//  Der Winkel kommt als ValueListenable herein, nicht als einfache Zahl.
//  Dadurch baut sich nur die Anzeige neu auf - nicht der ganze Bildschirm
//  mit allen Kacheln, Texten und Tasten.
// ---------------------------------------------------------------------------

/// Mittelpunkt der Skala. Beide Ebenen MUESSEN dieselbe Rechnung
/// benutzen, sonst passt der Zeiger nicht zur Skala.
Offset _center(Size size) => Offset(size.width / 2, size.height * 0.82);

double _radius(Size size) {
  final c = _center(size);
  return math.min(size.width * 0.42, c.dy * 0.82);
}

Offset _polar(Offset c, double r, double deg) {
  final a = deg * math.pi / 180;
  return Offset(c.dx + r * math.sin(a), c.dy - r * math.cos(a));
}

/// Schraeglagen-Anzeige: Skala von -60 bis +60 Grad, Farbzonen,
/// Marker fuer die Maximalwerte und ein Motorrad in Heckansicht,
/// das mit dem Zeiger mitlehnt.
class LeanGauge extends StatelessWidget {
  const LeanGauge({
    super.key,
    required this.lean,
    this.maxL = 0,
    this.maxR = 0,
  });

  /// Laufender Schraeglagenwert in Grad, positiv = rechts.
  final ValueListenable<double> lean;

  final double maxL;
  final double maxR;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 400 / 250,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Untere Ebene: Skala. Wird praktisch nur einmal gezeichnet.
          const RepaintBoundary(
            child: CustomPaint(painter: _ScalePainter()),
          ),
          // Obere Ebene: alles, was sich bewegt.
          RepaintBoundary(
            child: ValueListenableBuilder<double>(
              valueListenable: lean,
              builder: (context, roll, _) => CustomPaint(
                painter: _NeedlePainter(roll: roll, maxL: maxL, maxR: maxR),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Untere Ebene: Skala, Striche, Zahlen, Horizont, Nullmarke
// ---------------------------------------------------------------------------
class _ScalePainter extends CustomPainter {
  const _ScalePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = _center(size);
    final r = _radius(size);

    // Horizontlinie
    final horizon = Paint()
      ..color = steel.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    for (double x = c.dx - r; x < c.dx + r; x += 9) {
      canvas.drawLine(Offset(x, c.dy), Offset(x + 3.5, c.dy), horizon);
    }

    // Farbzonen
    final sw = r * 0.072;
    void zone(double a1, double a2, Color col) {
      final p = Paint()
        ..color = col
        ..style = PaintingStyle.stroke
        ..strokeWidth = sw;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r),
          (a1 - 90) * math.pi / 180, (a2 - a1) * math.pi / 180, false, p);
    }

    zone(-60, -48, const Color(0xFFC22736));
    zone(-48, -35, const Color(0xFFB87D16));
    zone(-35, 35, const Color(0xFF222933));
    zone(35, 48, const Color(0xFFB87D16));
    zone(48, 60, const Color(0xFFC22736));

    // Striche und Zahlen
    final tickR = r * 0.94;
    final minor = Paint()
      ..color = const Color(0xFF5A6472)
      ..strokeWidth = 1.3;
    final major = Paint()
      ..color = chalk
      ..strokeWidth = 2.2;

    for (int a = -60; a <= 60; a += 5) {
      final isMajor = a % 15 == 0;
      canvas.drawLine(
        _polar(c, tickR, a.toDouble()),
        _polar(c, tickR - (isMajor ? r * 0.09 : r * 0.05), a.toDouble()),
        isMajor ? major : minor,
      );
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${a.abs()}',
            style: TextStyle(
              fontSize: r * 0.078,
              fontWeight: FontWeight.w600,
              color: steel,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final pos = _polar(c, tickR - r * 0.2, a.toDouble());
        tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
      }
    }

    // Nullmarke
    final zero = Path()
      ..moveTo(c.dx - r * 0.036, c.dy - r * 1.115)
      ..lineTo(c.dx + r * 0.036, c.dy - r * 1.115)
      ..lineTo(c.dx, c.dy - r * 1.055)
      ..close();
    canvas.drawPath(zero, Paint()..color = steel);
  }

  /// Die Skala ist unveraenderlich. Bei Groessenaenderung zeichnet
  /// Flutter ohnehin neu, dafuer ist dieser Wert nicht zustaendig.
  @override
  bool shouldRepaint(_ScalePainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Obere Ebene: Maximal-Marker, Zeiger, Motorrad
// ---------------------------------------------------------------------------
class _NeedlePainter extends CustomPainter {
  _NeedlePainter({required this.roll, required this.maxL, required this.maxR});

  final double roll;
  final double maxL;
  final double maxR;

  @override
  void paint(Canvas canvas, Size size) {
    final c = _center(size);
    final r = _radius(size);

    // Marker der bisherigen Maximalwerte
    final ghostPaint = Paint()
      ..color = signal.withValues(alpha: 0.95)
      ..strokeWidth = 3;
    void ghost(double deg) {
      if (deg.abs() < 1.5) return;
      final d = deg.clamp(-64.0, 64.0);
      canvas.drawLine(
          _polar(c, r * 0.955, d), _polar(c, r * 1.065, d), ghostPaint);
    }

    ghost(-maxL);
    ghost(maxR);

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(roll.clamp(-66.0, 66.0) * math.pi / 180);

    final needle = Path()
      ..moveTo(-r * 0.021, -r * 0.55)
      ..lineTo(0, -r * 0.9)
      ..lineTo(r * 0.021, -r * 0.55)
      ..close();
    canvas.drawPath(needle, Paint()..color = signal);

    // Motorrad in Heckansicht
    canvas.drawCircle(Offset(0, -r * 0.048), r * 0.078,
        Paint()..color = const Color(0xFF1B2027));
    canvas.drawCircle(
      Offset(0, -r * 0.048),
      r * 0.078,
      Paint()
        ..color = const Color(0xFF454F5C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.02,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(0, -r * 0.155), width: r * 0.18, height: r * 0.066),
        Radius.circular(r * 0.018),
      ),
      Paint()..color = const Color(0xFF2A323C),
    );
    final body = Path()
      ..moveTo(-r * 0.078, -r * 0.155)
      ..lineTo(r * 0.078, -r * 0.155)
      ..lineTo(r * 0.045, -r * 0.31)
      ..lineTo(-r * 0.045, -r * 0.31)
      ..close();
    canvas.drawPath(body, Paint()..color = const Color(0xFFC7CDD5));
    final torso = Path()
      ..moveTo(-r * 0.048, -r * 0.30)
      ..lineTo(r * 0.048, -r * 0.30)
      ..lineTo(r * 0.066, -r * 0.44)
      ..lineTo(-r * 0.066, -r * 0.44)
      ..close();
    canvas.drawPath(torso, Paint()..color = const Color(0xFF98A2AF));
    canvas.drawCircle(Offset(0, -r * 0.495), r * 0.06, Paint()..color = signal);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(0, -r * 0.5), radius: r * 0.042),
      math.pi * 1.15,
      math.pi * 0.7,
      false,
      Paint()
        ..color = asphalt
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.015,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_NeedlePainter old) =>
      old.roll != roll || old.maxL != maxL || old.maxR != maxR;
}

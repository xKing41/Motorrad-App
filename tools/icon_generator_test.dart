import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const out = String.fromEnvironment('OUT');
const bg = Color(0xFF0B0D10);
const orange = Color(0xFFFF5A0A);
const chalk = Color(0xFFF2F4F6);
const amber = Color(0xFFFFB020);
const red = Color(0xFFFF3141);

/// Vordergrund: Schraeglagen-Skala mit Zeiger. [s] = Kantenlaenge, Inhalt
/// im mittleren Bereich [safe] (Anteil).
void paintMark(Canvas c, double s, {double safe = 0.62, bool test = false}) {
  final r = s * safe / 2;
  final cx = s / 2, cy = s / 2 + r * 0.45;
  Offset p(double deg, double rad) {
    final a = (deg - 90) * math.pi / 180;
    return Offset(cx + rad * math.cos(a), cy + rad * math.sin(a));
  }
  final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
  // Bogen: grau, Enden amber/rot
  final arc = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = r * 0.20
    ..strokeCap = StrokeCap.butt;
  double rad(double d) => (d - 90) * math.pi / 180;
  arc.color = const Color(0xFF3A434F);
  c.drawArc(rect, rad(-62), rad(62) - rad(-62), false, arc);
  arc.color = amber;
  c.drawArc(rect, rad(-62), rad(-40) - rad(-62), false, arc);
  c.drawArc(rect, rad(40), rad(62) - rad(40), false, arc);
  arc.color = red;
  c.drawArc(rect, rad(-62), rad(-52) - rad(-62), false, arc);
  c.drawArc(rect, rad(52), rad(62) - rad(52), false, arc);
  // Striche
  final tick = Paint()
    ..color = chalk
    ..strokeWidth = r * 0.05
    ..strokeCap = StrokeCap.round;
  for (var d = -45.0; d <= 45; d += 15) {
    c.drawLine(p(d, r * 0.72), p(d, r * 0.86), tick);
  }
  // Zeiger (sportlich schraeg: 35 Grad)
  const lean = 35.0;
  final needle = Path()
    ..moveTo(p(lean, r * 1.02).dx, p(lean, r * 1.02).dy)
    ..lineTo(p(lean - 90, r * 0.07).dx, p(lean - 90, r * 0.07).dy)
    ..lineTo(p(lean + 90, r * 0.07).dx, p(lean + 90, r * 0.07).dy)
    ..close();
  c.drawPath(needle, Paint()..color = orange);
  c.drawCircle(Offset(cx, cy), r * 0.14, Paint()..color = orange);
  c.drawCircle(Offset(cx, cy), r * 0.06, Paint()..color = bg);
  if (test) {
    final band = Paint()..color = const Color(0xFF45A8E6);
    c.drawRect(Rect.fromLTWH(0, s * 0.80, s, s * 0.20), band);
  }
}

Future<void> save(String path, int w, int h, void Function(Canvas) draw) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  draw(c);
  final img = await rec.endRecording().toImage(w, h);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('icons', (tester) async {
    await tester.runAsync(() async {
      const dens = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
      for (final test in [false, true]) {
        final base = test ? '$out/res_test' : '$out/res';
        for (final e in dens.entries) {
          // Klassisches Symbol (48 dp), abgerundetes Quadrat.
          final s = (48 * e.value).round();
          await save('$base/mipmap-${e.key}/ic_launcher.png', s, s, (c) {
            final rr = RRect.fromRectAndRadius(
                Rect.fromLTWH(0, 0, s.toDouble(), s.toDouble()),
                Radius.circular(s * 0.18));
            c.clipRRect(rr);
            c.drawRect(Rect.fromLTWH(0, 0, s.toDouble(), s.toDouble()),
                Paint()..color = bg);
            paintMark(c, s.toDouble(), safe: 0.74, test: test);
          });
          // Adaptiver Vordergrund (108 dp, Inhalt in 66 dp).
          final f = (108 * e.value).round();
          await save('$base/mipmap-${e.key}/ic_launcher_foreground.png', f, f,
              (c) => paintMark(c, f.toDouble(), safe: 0.50, test: false));
        }
      }
      // Store-Symbol 512 und Kopfbild 1024 x 500.
      await save('$out/store/icon-512.png', 512, 512, (c) {
        c.drawRect(const Rect.fromLTWH(0, 0, 512, 512), Paint()..color = bg);
        paintMark(c, 512, safe: 0.74);
      });
      await save('$out/store/feature-1024x500.png', 1024, 500, (c) {
        c.drawRect(const Rect.fromLTWH(0, 0, 1024, 500), Paint()..color = bg);
        // Diagonale Streifen
        final stripe = Paint()..color = orange;
        final path = Path()
          ..moveTo(860, 0)
          ..lineTo(915, 0)
          ..lineTo(715, 500)
          ..lineTo(660, 500)
          ..close();
        c.drawPath(path, stripe);
        c.save();
        c.translate(560, 20);
        paintMark(c, 500, safe: 0.62);
        c.restore();
        final tp = TextPainter(
          text: const TextSpan(children: [
            TextSpan(text: 'SCHRÄG', style: TextStyle(color: chalk)),
            TextSpan(text: 'LAGE', style: TextStyle(color: orange)),
          ], style: TextStyle(
              fontFamily: 'Barlow', fontSize: 92, fontWeight: FontWeight.w800,
              fontStyle: FontStyle.italic)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(c, const Offset(60, 150));
        final sub = TextPainter(
          text: const TextSpan(
              text: 'Kurvige Touren. Sicher ankommen.',
              style: TextStyle(fontFamily: 'Barlow', fontSize: 38,
                  fontWeight: FontWeight.w600, color: Color(0xFF97A1AE))),
          textDirection: TextDirection.ltr,
        )..layout();
        sub.paint(c, const Offset(64, 270));
      });
    });
  });

  setUpAll(() async {
    final l = FontLoader('Barlow');
    for (final w in ['Bold', 'ExtraBold', 'SemiBold', 'BoldItalic']) {
      l.addFont(Future.value(ByteData.view(File('assets/fonts/BarlowSemiCondensed-$w.ttf').readAsBytesSync().buffer)));
    }
    await l.load();
  });
}


import 'package:flutter/material.dart';

/// Zentrale Farb- und Stil-Definitionen.
/// Alle Screens greifen hierauf zu, damit das Design konsistent bleibt.

const asphalt = Color(0xFF0B0D10);
const panel = Color(0xFF14181E);
const line = Color(0xFF232A33);
const chalk = Color(0xFFEDEFF2);
const steel = Color(0xFF7E8794);
const signal = Color(0xFFFF4D00);
const amber = Color(0xFFFFB020);
const redline = Color(0xFFFF3141);
const cool = Color(0xFF3A9BD9);

/// Farbe fuer einen Schraeglagenwert (Betrag in Grad).
Color leanColor(double absDeg) {
  if (absDeg >= 48) return redline;
  if (absDeg >= 35) return amber;
  if (absDeg >= 20) return signal;
  if (absDeg >= 8) return const Color(0xFF7FBF4F);
  return cool;
}

ThemeData buildTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: asphalt,
    colorScheme: const ColorScheme.dark(primary: signal, surface: panel),
    fontFamily: 'monospace',
    appBarTheme: const AppBarTheme(
      backgroundColor: asphalt,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 14,
        letterSpacing: 4,
        fontWeight: FontWeight.w700,
        color: chalk,
      ),
    ),
  );
}

/// Kleines Label ueber einem Wert.
class TinyLabel extends StatelessWidget {
  const TinyLabel(this.text, {super.key, this.color = steel});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(fontSize: 8.5, letterSpacing: 2.2, color: color),
      );
}

/// Kachel im typischen Dashboard-Look mit farbiger Kante links.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.unit = '',
    this.sub,
    this.accent = signal,
  });

  final String label;
  final String value;
  final String unit;
  final String? sub;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: panel,
        border: Border(
          left: BorderSide(color: accent, width: 3),
          top: const BorderSide(color: line),
          right: const BorderSide(color: line),
          bottom: const BorderSide(color: line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TinyLabel(label),
          const SizedBox(height: 1),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                  color: chalk,
                ),
              ),
              if (unit.isNotEmpty)
                Text(unit, style: const TextStyle(fontSize: 14, color: steel)),
              if (sub != null) ...[
                const Spacer(),
                Text(sub!, style: const TextStyle(fontSize: 9, color: steel)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Flacher Button im Dashboard-Stil.
class FlatButton2 extends StatelessWidget {
  const FlatButton2({
    super.key,
    required this.label,
    required this.onTap,
    this.color = steel,
    this.strong = false,
    this.onLongPress,
    this.tall = false,
    this.fill,
  });

  /// Hintergrund - ueber der Karte noetig, sonst ist der Knopf kaum zu
  /// sehen. Ist er gleich [color], wird die Schrift dunkel.
  final Color? fill;

  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Hoeher - fuer die Bedienung mit Handschuhen waehrend der Fahrt.
  final bool tall;
  final Color color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      onLongPress: onLongPress,
      style: OutlinedButton.styleFrom(
        backgroundColor: fill,
        foregroundColor: color,
        side: BorderSide(color: color, width: strong ? 1.4 : 1),
        padding: EdgeInsets.symmetric(vertical: tall ? 18 : (strong ? 13 : 11)),
        shape: const RoundedRectangleBorder(),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: strong ? 11.5 : 9.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.4,
          color: fill == color ? asphalt : (strong ? color : chalk),
        ),
      ),
    );
  }
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(
        msg,
        textAlign: TextAlign.center,
        style: const TextStyle(letterSpacing: 1.4, color: chalk),
      ),
      backgroundColor: panel,
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: signal),
      ),
      duration: const Duration(milliseconds: 1500),
    ));
}

String fmtDur(int s) {
  if (s >= 3600) {
    final h = s ~/ 3600;
    final m = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
    return '$h:$m h';
  }
  final m = s ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return '$m:$sec min';
}

String fmtDate(DateTime d) {
  String p(int v) => v.toString().padLeft(2, '0');
  return '${p(d.day)}.${p(d.month)}.${d.year}  ${p(d.hour)}:${p(d.minute)}';
}

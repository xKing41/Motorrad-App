import 'dart:math' as math;


import 'package:flutter/material.dart';

/// Zentrale Farb- und Stil-Definitionen.
/// Alle Screens greifen hierauf zu, damit das Design konsistent bleibt.

/// Schrift der App: schmal und kraeftig (Barlow Semi Condensed) - viel
/// Text auf wenig Platz, auch mit Helm und in der Sonne gut lesbar.
const kFont = 'Barlow';

/// Mindestgroesse fuer alles, was man waehrend der Fahrt antippt
/// (Handschuh). Sonst mindestens 48.
const double kTouchRide = 60;
const double kTouch = 48;

const asphalt = Color(0xFF0B0D10);
const panel = Color(0xFF151A21);
const panel2 = Color(0xFF1D242D);
const line = Color(0xFF2A323D);
const chalk = Color(0xFFF2F4F6);

/// Nebentext - heller als frueher (Lesbarkeit in der Sonne).
const steel = Color(0xFF97A1AE);
const signal = Color(0xFFFF5A0A);
const amber = Color(0xFFFFB020);
const redline = Color(0xFFFF3141);
const cool = Color(0xFF45A8E6);
const go = Color(0xFF7FBF4F);

/// Zahlen gleich breit - springen beim Hochzaehlen nicht hin und her.
const tabular = [FontFeature.tabularFigures()];

/// Sportliche Ecken: schraeg abgeschnitten statt rund.
const OutlinedBorder kShape =
    BeveledRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(7)));

/// Farbe fuer einen Schraeglagenwert (Betrag in Grad).
Color leanColor(double absDeg) {
  if (absDeg >= 48) return redline;
  if (absDeg >= 35) return amber;
  if (absDeg >= 20) return signal;
  if (absDeg >= 8) return go;
  return cool;
}

ThemeData buildTheme() {
  const text = TextTheme(
    displayLarge: TextStyle(fontSize: 56, fontWeight: FontWeight.w800),
    headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
    titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
    titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    bodyLarge: TextStyle(fontSize: 17),
    bodyMedium: TextStyle(fontSize: 16),
    bodySmall: TextStyle(fontSize: 14, color: steel),
    labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
  );
  const btnText = TextStyle(
      fontFamily: kFont,
      fontSize: 16,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8);
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: asphalt,
    colorScheme: const ColorScheme.dark(
      primary: signal,
      onPrimary: asphalt,
      secondary: cool,
      surface: panel,
      onSurface: chalk,
      error: redline,
    ),
    fontFamily: kFont,
    textTheme: text.apply(bodyColor: chalk, displayColor: chalk),
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: const AppBarTheme(
      backgroundColor: asphalt,
      elevation: 0,
      toolbarHeight: 60,
      iconTheme: IconThemeData(size: 28, color: chalk),
      titleTextStyle: TextStyle(
        fontFamily: kFont,
        fontSize: 21,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w800,
        fontStyle: FontStyle.italic,
        color: chalk,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(kTouch, 52),
        shape: kShape,
        textStyle: btnText,
        backgroundColor: signal,
        foregroundColor: asphalt,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(kTouch, 52),
        shape: kShape,
        textStyle: btnText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(kTouch, kTouch),
        textStyle: btnText,
        foregroundColor: signal,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(kTouch, kTouch)),
    ),
    listTileTheme: const ListTileThemeData(
      minVerticalPadding: 10,
      minTileHeight: 56,
      iconColor: steel,
      titleTextStyle: TextStyle(fontFamily: kFont, fontSize: 17, color: chalk),
      subtitleTextStyle:
          TextStyle(fontFamily: kFont, fontSize: 14, color: steel, height: 1.3),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? asphalt : steel),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? signal : line),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 6,
      activeTrackColor: signal,
      inactiveTrackColor: line,
      thumbColor: signal,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 13),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 26),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: panel,
      selectedColor: signal,
      side: BorderSide(color: line),
      shape: kShape,
      labelStyle: TextStyle(fontFamily: kFont, fontSize: 15, color: chalk),
      padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: panel,
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      hintStyle: TextStyle(fontFamily: kFont, fontSize: 16, color: steel),
      labelStyle: TextStyle(fontFamily: kFont, fontSize: 16, color: steel),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero, borderSide: BorderSide(color: line)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(color: signal, width: 2)),
      border: OutlineInputBorder(borderRadius: BorderRadius.zero),
    ),
    tabBarTheme: const TabBarThemeData(
      labelStyle: TextStyle(
          fontFamily: kFont, fontSize: 16, fontWeight: FontWeight.w800),
      unselectedLabelStyle: TextStyle(
          fontFamily: kFont, fontSize: 16, fontWeight: FontWeight.w600),
      labelColor: chalk,
      unselectedLabelColor: steel,
      indicatorColor: signal,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: panel,
      shape: kShape,
      titleTextStyle: TextStyle(
          fontFamily: kFont,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: chalk),
      contentTextStyle: TextStyle(
          fontFamily: kFont, fontSize: 16, color: steel, height: 1.4),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: panel,
      shape: RoundedRectangleBorder(),
      showDragHandle: true,
      dragHandleColor: steel,
    ),
    snackBarTheme: const SnackBarThemeData(
      contentTextStyle: TextStyle(fontFamily: kFont, fontSize: 16, color: chalk),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      iconColor: signal,
      collapsedIconColor: steel,
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
        style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.3,
            color: color),
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
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  fontFeatures: tabular,
                  color: chalk,
                ),
              ),
              if (unit.isNotEmpty)
                Text(unit, style: const TextStyle(fontSize: 17, color: steel)),
              if (sub != null) ...[
                const Spacer(),
                Text(sub!, style: const TextStyle(fontSize: 13, color: steel)),
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
        side: BorderSide(color: color, width: strong ? 2 : 1.4),
        minimumSize: Size(kTouch, tall ? kTouchRide : 52),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: kShape,
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: tall || strong ? 17 : 15,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: fill == color ? asphalt : (strong ? color : chalk),
        ),
      ),
    );
  }
}

/// Kurze Meldung - in der oberen Bildschirmhaelfte: verdeckt weder die
/// grossen Knoepfe unten noch die Abbiegeanzeige oben.
void toast(BuildContext context, String msg) {
  final mq = MediaQuery.of(context);
  final bottom = math.max(16.0, mq.size.height * 0.52);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(
        msg,
        textAlign: TextAlign.center,
        style: const TextStyle(
            fontSize: 16, fontWeight: FontWeight.w600, color: chalk),
      ),
      backgroundColor: panel2,
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.fromLTRB(16, 0, 16, bottom),
      dismissDirection: DismissDirection.up,
      shape: const BeveledRectangleBorder(
        side: BorderSide(color: signal, width: 1.5),
        borderRadius: BorderRadius.all(Radius.circular(7)),
      ),
      // Lang genug, um es auch waehrend der Fahrt lesen zu koennen.
      duration: const Duration(milliseconds: 3000),
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

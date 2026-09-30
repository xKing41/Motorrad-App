import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import 'emergency_screen.dart';

/// Kurzer Einstieg beim ersten Start: drei Seiten, was die App kann und
/// wie man sie mit Handschuhen bedient.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key});

  static const _key = 'intro_v1';

  /// Einmal zeigen (nach dem ersten Bild der App).
  static Future<void> showOnce(BuildContext context) async {
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool(_key) == true || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => const IntroScreen()));
    await sp.setBool(_key, true);
  }

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  final _pages = PageController();
  int _page = 0;

  static const _items = [
    (
      Icons.route,
      'TOUREN PLANEN',
      'Rundtour oder von A nach B - kurvig, ohne Autobahn, mit Tank- '
          'und Pausenstopps. Jede Tour wird auf Motorradverbote, Feldwege '
          'und Schotter geprüft.',
    ),
    (
      Icons.back_hand_outlined,
      'MIT HANDSCHUH',
      'Große Knöpfe, während der Navigation nur drei. Alles Weitere liegt '
          'im MENÜ. Beenden geht nur durch Gedrückthalten - ein '
          'versehentlicher Tipp beendet nichts.',
    ),
    (
      Icons.my_location,
      'DEIN STANDORT',
      'Gleich fragt Android nach deinem Standort. Ohne ihn gibt es keine '
          'Karte, kein Navi und keine Sturzerkennung. Er bleibt auf deinem '
          'Handy - im Hintergrund nur, solange du eine Fahrt aufzeichnest '
          'oder navigierst.',
    ),
    (
      Icons.emergency_outlined,
      'SICHER UNTERWEGS',
      'Die Sturzerkennung schickt im Ernstfall eine SMS mit deiner '
          'Position. Dafür braucht die App einen Notfallkontakt.',
    ),
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < _items.length - 1) {
      _pages.nextPage(
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _items.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Column(children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ÜBERSPRINGEN',
                    style: TextStyle(color: steel)),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  for (final (icon, title, text) in _items)
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon, size: 84, color: signal),
                        const SizedBox(height: 24),
                        Text(title,
                            style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                                fontStyle: FontStyle.italic,
                                color: chalk)),
                        const SizedBox(height: 14),
                        Text(text,
                            style: const TextStyle(
                                fontSize: 19, color: steel, height: 1.4)),
                      ],
                    ),
                ],
              ),
            ),
            Row(children: [
              for (var i = 0; i < _items.length; i++)
                Container(
                  width: i == _page ? 28 : 10,
                  height: 6,
                  margin: const EdgeInsets.only(right: 6),
                  color: i == _page ? signal : line,
                ),
            ]),
            const SizedBox(height: 20),
            if (last) ...[
              SizedBox(
                width: double.infinity,
                child: FlatButton2(
                  label: 'NOTFALLKONTAKT EINTRAGEN',
                  color: cool,
                  strong: true,
                  tall: true,
                  onTap: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const EmergencyScreen()));
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: FlatButton2(
                label: last ? 'LOS GEHT\'S' : 'WEITER',
                color: signal,
                fill: signal,
                strong: true,
                tall: true,
                onTap: _next,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

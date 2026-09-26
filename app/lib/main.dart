import 'dart:async';

import 'package:flutter/material.dart';

import 'build_flavor.dart';
import 'screens/dashboard_screen.dart';
import 'screens/map_screen.dart';
import 'screens/rides_screen.dart';
import 'screens/crash_alarm_screen.dart';
import 'services/companion.dart';
import 'services/emergency.dart';
import 'services/power.dart';
import 'services/ride_store.dart';
import 'services/telemetry.dart';
import 'services/vector_map.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LeanApp());
}

class LeanApp extends StatelessWidget {
  const LeanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      // Test-App deutlich kennzeichnen - damit niemand sie mit der
      // echten verwechselt.
      builder: kTestBuild
          ? (context, child) => Banner(
                message: 'TEST',
                location: BannerLocation.topEnd,
                color: cool,
                child: child!,
              )
          : null,
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final t = Telemetry.instance;
  final _ridesKey = GlobalKey<RidesScreenState>();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PowerPolicy.instance.init();
    // Notfalldaten liegen auf dem Geraet und muessen vor der ersten
    // Sturzpruefung geladen sein.
    Emergency.instance.load();
    // Vektorkarte vorbereiten (Stile laden, Kachel-Adresse holen).
    VectorMap.instance.init();
    t.start();
    t.addListener(_onTick);
    t.crashAlarm.addListener(_onCrashAlarm);
    // Laufende Fahrt jede Minute sichern.
    _backupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final s = t.currentSummary();
      if (s != null) RideStore.instance.saveActive(s, List.of(t.track));
      // Begleit-SMS: Position in festen Abstaenden.
      if (t.recording) {
        _companion.tick(DateTime.now(), t.rideDistanceM / 1000,
            lat: t.lat, lon: t.lon);
      }
    });
    _recover();
  }

  Timer? _backupTimer;
  final Companion _companion = Companion(Emergency.instance);

  /// Wurde die App beim letzten Mal waehrend einer Fahrt beendet?
  Future<void> _recover() async {
    final r = await RideStore.instance.recoverActive();
    if (r == null || !mounted) return;
    await _ridesKey.currentState?.reload();
    if (mounted) {
      toast(context,
          'Unterbrochene Fahrt gerettet · ${r.distanceKm.toStringAsFixed(1)} km');
    }
  }

  @override
  void dispose() {
    _backupTimer?.cancel();
    t.removeListener(_onTick);
    t.crashAlarm.removeListener(_onCrashAlarm);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// App sichtbar oder nicht - ohne Fahrt wird im Hintergrund alles
  /// abgeschaltet (Akku).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    t.setForeground(state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive);
  }

  bool _lastRecording = false;
  bool _alarmOpen = false;

  /// Sturzverdacht: Vollbild-Alarm mit Countdown oeffnen.
  ///
  /// Der Alarm liegt ueber allem anderen, damit er auch dann sichtbar ist,
  /// wenn gerade die Karte oder ein Untermenue offen war.
  Future<void> _onCrashAlarm() async {
    if (!mounted || _alarmOpen) return;
    _alarmOpen = true;
    await Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CrashAlarmScreen(lat: t.lat, lon: t.lon),
    ));
    _alarmOpen = false;
  }

  void _onTick() {
    // Die Screens aktualisieren sich selbst. Hier reicht es, auf den
    // Wechsel des Aufnahmestatus zu reagieren (Punkt im Karten-Tab).
    if (t.recording != _lastRecording) {
      _lastRecording = t.recording;
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggleRide() async {
    if (!t.recording) {
      t.startRecording();
      if (mounted) toast(context, 'Fahrt gestartet – gute Fahrt!');
      unawaited(_companion.rideStarted(DateTime.now(), lat: t.lat, lon: t.lon));
      await _firstRideSetup();
      return;
    }

    final summary = t.stopRecording();
    if (summary == null) return;
    unawaited(_companion.rideEnded(DateTime.now(), summary.distanceKm));
    await RideStore.instance.clearActive();
    // Aus Versehen gestartet und gleich wieder beendet: nicht als Fahrt
    // in die Liste schreiben.
    if (summary.durationSec < 30 && summary.distanceM < 100) {
      if (mounted) toast(context, 'Fahrt zu kurz – nicht gespeichert');
      return;
    }
    await RideStore.instance.saveRide(summary, List.of(t.track));
    // Eine letzte Zwischensicherung koennte noch unterwegs gewesen sein.
    await RideStore.instance.clearActive();
    await _ridesKey.currentState?.reload();
    if (mounted) {
      toast(context,
          'Fahrt gespeichert · ${summary.distanceKm.toStringAsFixed(1)} km');
    }
  }

  /// Vor der ersten Fahrt einmal: Benachrichtigung erlauben und auf die
  /// Akku-Optimierung hinweisen. Manche Hersteller (Samsung, Xiaomi,
  /// Huawei ...) beenden sonst die Aufzeichnung im Hintergrund.
  Future<void> _firstRideSetup() async {
    final askBattery = await PowerPolicy.instance.prepareFirstRide();
    if (!askBattery || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: panel,
        shape: const RoundedRectangleBorder(side: BorderSide(color: line)),
        title: const Text('AUFZEICHNUNG IM HINTERGRUND',
            style: TextStyle(fontSize: 12, letterSpacing: 2, color: chalk)),
        content: const Text(
          'Die Fahrt läuft auch bei ausgeschaltetem Bildschirm weiter. '
          'Manche Handys beenden Apps im Hintergrund trotzdem, um Akku zu '
          'sparen. Wenn du "Akku-Optimierung" für Schräglage ausschaltest, '
          'passiert das nicht.\n\nDas kostet selbst keinen Akku - '
          'Schräglage misst nur während einer Fahrt.',
          style: TextStyle(fontSize: 11.5, color: steel, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('SPÄTER',
                style: TextStyle(fontSize: 11, color: steel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('EINSTELLUNG ÖFFNEN',
                style: TextStyle(fontSize: 11, color: signal)),
          ),
        ],
      ),
    );
    if (ok == true) await PowerPolicy.instance.openBatterySettings();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          DashboardScreen(onToggleRide: _toggleRide),
          MapScreen(onToggleRide: _toggleRide),
          SafeArea(child: RidesScreen(key: _ridesKey)),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: panel,
          border: Border(top: BorderSide(color: line)),
        ),
        child: BottomNavigationBar(
          currentIndex: _tab,
          onTap: (i) {
            setState(() => _tab = i);
            // Zeigerkanal nur laufen lassen, wenn das Cockpit zu sehen ist.
            t.setLeanLive(i == 0);
            if (i == 2) _ridesKey.currentState?.reload();
          },
          backgroundColor: Colors.transparent,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: signal,
          unselectedItemColor: steel,
          selectedLabelStyle:
              const TextStyle(fontSize: 9, letterSpacing: 2),
          unselectedLabelStyle:
              const TextStyle(fontSize: 9, letterSpacing: 2),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.speed, size: 20),
              label: 'COCKPIT',
            ),
            BottomNavigationBarItem(
              icon: Stack(clipBehavior: Clip.none, children: [
                const Icon(Icons.map, size: 20),
                if (t.recording)
                  Positioned(
                    right: -3,
                    top: -2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                          color: signal, shape: BoxShape.circle),
                    ),
                  ),
              ]),
              label: 'KARTE',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.list_alt, size: 20),
              label: 'FAHRTEN',
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'build_flavor.dart';
import 'screens/dashboard_screen.dart';
import 'screens/map_screen.dart';
import 'screens/rides_screen.dart';
import 'screens/crash_alarm_screen.dart';
import 'screens/feedback_screen.dart';
import 'screens/intro_screen.dart';
import 'services/companion.dart';
import 'services/crash_log.dart';
import 'services/emergency.dart';
import 'services/group_ride.dart';
import 'services/power.dart';
import 'services/ride_store.dart';
import 'services/telemetry.dart';
import 'services/user_blocks.dart';
import 'services/vector_map.dart';
import 'services/voice.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Fehler festhalten (nur auf dem Handy, verschickt nur mit Zustimmung).
  CrashLog.instance.install();
  // Lizenz der Schrift in der Lizenzseite zeigen.
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/OFL-Barlow.txt');
    yield LicenseEntryWithLineBreaks(['Barlow (Schrift)'], text);
  });
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
    Emergency.instance.load().then((_) {
      // Gruppen (Test-App): gemerkte Gruppen wieder verbinden.
      if (kTestBuild) {
        final n = Emergency.instance.riderName.trim();
        GroupHub.instance.restore(n.isEmpty ? 'Fahrer' : n);
      }
    });
    // Vektorkarte vorbereiten (Stile laden, Kachel-Adresse holen).
    VectorMap.instance.init();
    // Eigene Sperrliste: gilt fuer jede Routenberechnung.
    UserBlocks.instance.load();
    t.addListener(_onTick);
    t.crashAlarm.addListener(_onCrashAlarm);
    // Laufende Fahrt jede Minute sichern.
    _backupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      final s = t.currentSummary();
      if (s != null) RideStore.instance.saveActive(s, List.of(t.track));
      if (t.recording) unawaited(_readBattery());
      // Begleit-SMS: Position in festen Abstaenden.
      if (t.recording) {
        _companion.tick(DateTime.now(), t.rideDistanceM / 1000,
            lat: t.lat, lon: t.lon);
      }
    });
    _recover();
    // Beim allerersten Start: kurzer Einstieg. Sonst: gab es beim
    // letzten Mal einen Absturz? Dann fragen, ob der Bericht raus soll.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await IntroScreen.showOnce(context);
      // Erst nach dem Einstieg starten: dann kommt die Frage nach dem
      // Standort mit Erklaerung statt unvermittelt beim ersten Start.
      unawaited(t.start());
      unawaited(Voice.instance.warmUp());
      if (mounted && await CrashLog.instance.takePending() && mounted) {
        await FeedbackScreen.offerCrashReport(context);
      }
    });
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
    final fg = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    t.setForeground(fg);
    // Gruppen: im Hintergrund ohne Fahrt keine Dauerverbindung (Akku).
    if (kTestBuild) {
      if (fg) {
        GroupHub.instance.resume();
      } else if (!t.recording && !t.navigating) {
        GroupHub.instance.pause();
      }
    }
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
      unawaited(_readBattery());
      if (mounted) toast(context, 'Fahrt gestartet – gute Fahrt!');
      unawaited(_companion.rideStarted(DateTime.now(), lat: t.lat, lon: t.lon));
      await _firstRideSetup();
      return;
    }

    await _readBattery();
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

  Future<void> _readBattery() async {
    final b = await PowerPolicy.battery();
    if (b != null) t.noteBattery(b.$1, b.$2);
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
            style: TextStyle(fontSize: 15.5, letterSpacing: 1.2, color: chalk)),
        content: const Text(
          'Die Fahrt läuft auch bei ausgeschaltetem Bildschirm weiter. '
          'Manche Handys beenden Apps im Hintergrund trotzdem, um Akku zu '
          'sparen. Wenn du "Akku-Optimierung" für Schräglage ausschaltest, '
          'passiert das nicht.\n\nDas kostet selbst keinen Akku - '
          'Schräglage misst nur während einer Fahrt.',
          style: TextStyle(fontSize: 15, color: steel, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('SPÄTER',
                style: TextStyle(fontSize: 14.5, color: steel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('EINSTELLUNG ÖFFNEN',
                style: TextStyle(fontSize: 14.5, color: signal)),
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
          iconSize: 28,
          selectedFontSize: 14,
          unselectedFontSize: 14,
          selectedLabelStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w800, letterSpacing: 1),
          unselectedLabelStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 1),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.speed, size: 28),
              label: 'COCKPIT',
            ),
            BottomNavigationBarItem(
              icon: Stack(clipBehavior: Clip.none, children: [
                const Icon(Icons.map, size: 28),
                if (t.recording)
                  Positioned(
                    right: -3,
                    top: -2,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                          color: signal, shape: BoxShape.circle),
                    ),
                  ),
              ]),
              label: 'KARTE',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.list_alt, size: 28),
              label: 'FAHRTEN',
            ),
          ],
        ),
      ),
    );
  }
}

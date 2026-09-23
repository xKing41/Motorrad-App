import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ride.dart';
import 'crash_detector.dart';
import 'emergency.dart';
import 'mount.dart';
import 'weather_service.dart';

/// Zentrale Messwerterfassung: Schraeglage, Tempo, G-Kraefte, Track.
///
/// Messprinzip Schraeglage:
///  - Gyroskop liefert schnelle Aenderungen (driftet langsam weg)
///  - Bei Fahrt dient die physikalisch korrekte GPS-Methode als Referenz:
///    Schraeglage = asin(v * Gierrate / g)
///  - Im Stand stuetzt der Beschleunigungssensor
///  Ein Komplementaerfilter fuehrt beides zusammen.
///
/// Singleton, damit Dashboard und Karte dieselben Werte sehen.
class Telemetry extends ChangeNotifier {
  // --- Sicherheit ---------------------------------------------------
  /// Meldet einen Sturzverdacht an die Oberflaeche. Die Oberflaeche
  /// entscheidet, was zu tun ist - der Dienst kennt keine Bildschirme.
  final ValueNotifier<int> crashAlarm = ValueNotifier<int>(0);

  late final CrashDetector _crash = CrashDetector(
    onSuspectedCrash: () => crashAlarm.value = crashAlarm.value + 1,
  );

  // --- Wetter ------------------------------------------------------
  RideWeather? weather;
  Timer? _weatherTimer;
  int _weatherFailMs = 0;
  int _weatherAtMs = 0;
  bool _weatherBusy = false;

  /// Schneller Kanal ausschliesslich fuer die Schraeglagen-Anzeige.
  ///
  /// Der Zeiger haengt hieran und wird bei jedem Sensorwert aktualisiert
  /// (etwa 50-mal je Sekunde). notifyListeners() laeuft weiter im
  /// langsamen Takt fuer Kacheln und Texte - die brauchen kein Tempo und
  /// wuerden bei jedem Bild den halben Bildschirm neu aufbauen.
  final ValueNotifier<double> lean = ValueNotifier<double>(0);

  /// Alle Tabs bleiben im Hintergrund geladen. Ohne diesen Schalter
  /// wuerde die Anzeige auch dann 50-mal je Sekunde neu aufgebaut, wenn
  /// gerade die Karte zu sehen ist - verschenkte Rechenzeit, die dort
  /// beim Scrollen fehlt. Die Messung selbst laeuft immer weiter.
  bool _leanLive = true;

  void setLeanLive(bool v) {
    _leanLive = v;
    if (v) lean.value = roll;
  }

  Telemetry._();
  static final Telemetry instance = Telemetry._();

  // --- Sensor-Abos ---
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<UserAccelerometerEvent>? _linSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<Position>? _posSub;
  Timer? _uiTimer;
  Timer? _autoCalTimer;
  bool _started = false;

  // --- Energie ---------------------------------------------------------
  // Das Handy ist das ganze System - Akku ist knapp. Deshalb laeuft nur,
  // was gerade gebraucht wird:
  //   Fahrt/Navigation  -> volles GPS jede Sekunde, Sensoren 50 Hz, als
  //                        Vordergrunddienst (laeuft bei Bildschirm aus
  //                        und in anderen Apps weiter)
  //   App offen, keine Fahrt -> sparsames GPS, Sensoren fuer die Anzeige
  //   App im Hintergrund, keine Fahrt -> alles aus
  bool _foreground = true;
  bool navigating = false;
  GpsMode _gpsMode = GpsMode.off;
  bool _sensorsOn = false;

  bool get foreground => _foreground;
  bool get active => recording || navigating;
  GpsMode get gpsMode => _gpsMode;

  // --- Schwerkraft (tiefpassgefiltert, Geraetesystem) ---
  double _gx = 0, _gy = 9.81, _gz = 0;
  bool _hasAccel = false;

  // --- lineare Beschleunigung ohne Schwerkraft ---
  double _lx = 0, _ly = 0, _lz = 0;

  // --- Lage des Handys am Motorrad (oben, rechts, vorn) ---
  MountFrame _frame = MountFrame.portrait;

  /// Monotone Uhr fuer die Zeitschritte der Sensorfusion.
  /// DateTime.now() waere hier falsch: Die Kalenderzeit kann springen
  /// (Zeitumstellung, Abgleich mit dem Mobilfunknetz). Ein Sprung
  /// verfaelscht dt und damit den Winkel. Ein Stopwatch laeuft
  /// gleichmaessig weiter und ist ausserdem schneller abzufragen.
  final Stopwatch _clock = Stopwatch()..start();
  int _lastGyroUs = 0;
  int _lastAccUs = 0;
  int _lastLinUs = 0;
  bool _calibrated = false;

  // --- oeffentliche Messwerte ---
  double roll = 0; // Grad, + = rechts
  double maxLeanL = 0, maxLeanR = 0;
  double longG = 0; // + beschleunigen, - bremsen
  double latG = 0;
  double maxBrakeG = 0, maxLatG = 0;
  bool gpsReference = false; // true = GPS-gestuetzter Praezisionsmodus

  // --- Position ---
  double speedMs = -1;
  double? lat, lon, altM;
  double gpsAccuracyM = 999;

  /// Fahrtrichtung laut GPS in Grad (nur in Bewegung verlaesslich).
  double? headingDeg;
  DateTime? _fixTime;
  bool gpsDenied = false;
  bool gpsServiceOff = false;

  bool get hasFix =>
      _fixTime != null &&
      DateTime.now().difference(_fixTime!).inSeconds < 3 &&
      lat != null;

  double get speedKmh => speedMs > 0 ? speedMs * 3.6 : 0;

  // --- Aufzeichnung ---
  bool recording = false;
  DateTime? rideStart;
  double rideDistanceM = 0;
  double rideMaxSpeedMs = 0;
  final List<TrackPoint> track = [];
  int _lastRecMs = 0;
  // Letzter Punkt, bis zu dem die Strecke schon gezaehlt ist.
  double? _lastDistLat, _lastDistLon;
  int _lastDistMs = 0;

  int get rideDurationSec => rideStart == null
      ? 0
      : DateTime.now().difference(rideStart!).inSeconds;

  // ---------------------------------------------------------------
  // Start / Stop
  // ---------------------------------------------------------------
  Future<void> start() async {
    if (_started) return;
    _started = true;

    await _checkGpsPermission();
    await _applyPowerMode();

    // 200 ms genuegen fuer Zahlen und Kacheln. Der Zeiger haengt nicht
    // mehr an diesem Takt, sondern am ValueNotifier oben.
    _uiTimer =
        Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());

    // Alle 2 Minuten nachsehen - abgerufen wird aber nur, wenn die Daten
    // aelter als 15 Minuten sind (siehe refreshWeather).
    _weatherTimer = Timer.periodic(
        const Duration(minutes: 2), (_) => refreshWeather());

    // Gespeicherte Lage vom letzten Nullpunkt. Ohne sie wird einmal
    // automatisch kalibriert - dann bitte am montierten Handy den
    // Nullpunkt neu setzen.
    final saved = await _loadFrame();
    if (saved != null) {
      _frame = saved;
      _calibrated = true;
    }
    _autoCalTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!_calibrated && _hasAccel) calibrate(persist: false);
    });
  }

  Future<void> stop() async {
    _started = false;
    await _stopSensors();
    await _posSub?.cancel();
    _posSub = null;
    _gpsMode = GpsMode.off;
    _uiTimer?.cancel();
    _autoCalTimer?.cancel();
    _weatherTimer?.cancel();
  }

  /// App kommt in den Vordergrund oder geht in den Hintergrund.
  Future<void> setForeground(bool v) async {
    if (_foreground == v) return;
    _foreground = v;
    await _applyPowerMode();
  }

  /// Navigation laeuft (auch ohne Aufzeichnung: GPS muss weiterlaufen).
  Future<void> setNavigating(bool v) async {
    if (navigating == v) return;
    navigating = v;
    await _applyPowerMode();
    notifyListeners();
  }

  /// Welcher GPS-Modus zum aktuellen Zustand passt.
  static GpsMode gpsModeFor(
          {required bool active, required bool foreground}) =>
      active
          ? GpsMode.ride
          : (foreground ? GpsMode.idle : GpsMode.off);

  bool _applying = false;
  bool _applyAgain = false;

  Future<void> _applyPowerMode() async {
    if (!_started) return;
    // Nicht zwei Umschaltungen gleichzeitig - sonst laufen am Ende zwei
    // GPS-Abos.
    if (_applying) {
      _applyAgain = true;
      return;
    }
    _applying = true;
    try {
      do {
        _applyAgain = false;
        final wantSensors = active || _foreground;
        if (wantSensors && !_sensorsOn) _startSensors();
        if (!wantSensors && _sensorsOn) await _stopSensors();
        final mode = gpsModeFor(active: active, foreground: _foreground);
        if (mode != _gpsMode) await _startGps(mode);
      } while (_applyAgain);
    } finally {
      _applying = false;
    }
  }

  void _startSensors() {
    _sensorsOn = true;
    // 20 ms: Fuer "wo ist unten" wuerden 50 ms reichen (die Glaettung
    // ist zeitbasiert), aber die Sturzerkennung haengt am selben Strom.
    // Ein Aufprall dauert oft nur 10-30 ms - bei 50 ms Abstand faellt
    // die Spitze zwischen zwei Messwerte und wird nie gesehen.
    _lastAccUs = 0;
    _lastLinUs = 0;
    _lastGyroUs = 0;
    _accSub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen(_onAccel, onError: (_) {});
    _linSub = userAccelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen(_onLinear, onError: (_) {});
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen(_onGyro, onError: (_) {});
  }

  Future<void> _stopSensors() async {
    _sensorsOn = false;
    await _accSub?.cancel();
    await _linSub?.cancel();
    await _gyroSub?.cancel();
    _accSub = null;
    _linSub = null;
    _gyroSub = null;
  }

  Future<void> _checkGpsPermission() async {
    try {
      gpsServiceOff = !await Geolocator.isLocationServiceEnabled();
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      gpsDenied = p == LocationPermission.denied ||
          p == LocationPermission.deniedForever;
    } catch (_) {
      gpsDenied = true;
    }
  }

  /// Einstellungen je Modus. Fahrt: jede Sekunde, hoechste Genauigkeit,
  /// als Vordergrunddienst mit Benachrichtigung. Ohne Fahrt: alle paar
  /// Sekunden und nur bei Bewegung - das spart deutlich Akku.
  static LocationSettings settingsFor(GpsMode mode, {bool android = true}) {
    if (!android) {
      return LocationSettings(
        accuracy: mode == GpsMode.ride
            ? LocationAccuracy.bestForNavigation
            : LocationAccuracy.high,
        distanceFilter: mode == GpsMode.ride ? 0 : 10,
      );
    }
    if (mode == GpsMode.ride) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Schräglage – Fahrt läuft',
          notificationText:
              'Aufzeichnung, Navigation und Sturzerkennung laufen weiter.',
          notificationChannelName: 'Fahrt',
          // Haelt die CPU wach - sonst setzen die Sensoren (Schraeglage,
          // Sturzerkennung) bei ausgeschaltetem Bildschirm aus.
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    return AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
      intervalDuration: const Duration(seconds: 3),
    );
  }

  Future<void> _startGps(GpsMode mode) async {
    await _posSub?.cancel();
    _posSub = null;
    _gpsMode = mode;
    if (mode == GpsMode.off || gpsDenied) return;
    try {
      _posSub = Geolocator.getPositionStream(
        locationSettings: settingsFor(mode,
            android: defaultTargetPlatform == TargetPlatform.android),
      ).listen(_onPos, onError: (_) => gpsServiceOff = true);
    } catch (_) {
      gpsServiceOff = true;
    }
  }

  /// Erneuter Versuch, GPS zu starten (z. B. nachdem der Nutzer die
  /// Berechtigung nachtraeglich erteilt hat).
  ///
  /// Rueckgabe: Hinweis fuer den Nutzer oder null.
  Future<String?> retryGps() async {
    String? msg;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        await Geolocator.openLocationSettings();
        msg = 'Standort einschalten, dann erneut antippen';
      } else if (await Geolocator.checkPermission() ==
          LocationPermission.deniedForever) {
        // Android fragt dann nicht mehr nach - nur ueber die Einstellungen.
        await Geolocator.openAppSettings();
        msg = 'Unter Berechtigungen den Standort erlauben';
      }
    } catch (_) {}
    await _posSub?.cancel();
    _posSub = null;
    _gpsMode = GpsMode.off;
    await _checkGpsPermission();
    await _applyPowerMode();
    notifyListeners();
    return msg;
  }

  // ---------------------------------------------------------------
  // Sensor-Callbacks
  // ---------------------------------------------------------------
  /// Glaettungsfaktor aus Zeitschritt und Zeitkonstante.
  ///
  /// Vorher war der Faktor fest verdrahtet ("0.04 je Messwert"). Damit
  /// haing die Staerke der Glaettung davon ab, wie oft das Handy Werte
  /// liefert - und diese Rate haelt kein Geraet exakt ein. Auf einem
  /// schnellen Sensor wurde zu wenig geglaettet, auf einem langsamen zu
  /// viel. Ueber die Zeitkonstante ist das Verhalten jetzt auf jedem
  /// Geraet gleich.
  static double _alpha(double dt, double tau) {
    if (dt <= 0) return 0;
    return dt / (tau + dt);
  }

  void _onAccel(AccelerometerEvent e) {
    final us = _clock.elapsedMicroseconds;
    final dt = _lastAccUs == 0 ? 0.05 : (us - _lastAccUs) / 1e6;
    _lastAccUs = us;
    // 0,5 s Zeitkonstante: traege genug gegen Motorvibration.
    final a = _alpha(dt.clamp(0.0, 0.5), 0.5);
    _gx += a * (e.x - _gx);
    _gy += a * (e.y - _gy);
    _gz += a * (e.z - _gz);
    _hasAccel = true;

    // Sturzerkennung bekommt den ROHEN Wert inklusive Schwerkraft - der
    // geglaettete Wert wuerde jeden Aufprall wegbuegeln.
    if (Emergency.instance.autoDetect) {
      _crash.enabled = true;
      _crash.feedGravity(_gx, _gy, _gz);
      _crash.feedAccel(e.x, e.y, e.z, _clock.elapsedMilliseconds);
    } else {
      _crash.enabled = false;
    }
  }

  void _onLinear(UserAccelerometerEvent e) {
    final us = _clock.elapsedMicroseconds;
    final dt = _lastLinUs == 0 ? 0.02 : (us - _lastLinUs) / 1e6;
    _lastLinUs = us;
    // 0,15 s: schnell genug, um eine harte Bremsung zu erfassen.
    final a = _alpha(dt.clamp(0.0, 0.5), 0.15);
    _lx += a * (e.x - _lx);
    _ly += a * (e.y - _ly);
    _lz += a * (e.z - _lz);
    _updateForces();
  }

  double get _rollAcc => _frame.rollDeg(_gx, _gy, _gz);

  void _onGyro(GyroscopeEvent e) {
    final us = _clock.elapsedMicroseconds;
    final last = _lastGyroUs;
    _lastGyroUs = us;
    if (last == 0) return;
    final dt = (us - last) / 1e6;
    if (dt <= 0 || dt > 0.2) return;

    // Drehrate um die Vorwaertsachse = Schraeglagen-Aenderung
    final rate = _frame.rollRate(e.x, e.y, e.z) * 180 / math.pi;

    final upn = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    double refDeg;
    double tau;
    if (hasFix && speedMs > 2.5 && upn > 2) {
      final yaw = (e.x * _gx + e.y * _gy + e.z * _gz) / upn;
      final s = (-speedMs * yaw / 9.81).clamp(-0.999, 0.999).toDouble();
      refDeg = math.asin(s) * 180 / math.pi;
      tau = 1.4;
      gpsReference = true;
    } else {
      refDeg = _norm(_rollAcc);
      tau = 2.5;
      gpsReference = false;
    }

    final k = tau / (tau + dt);
    roll = _norm(k * (roll + rate * dt) + (1 - k) * refDeg);

    // Maximalwerte nur in Fahrt - der Seitenstaender (rund 15 Grad links)
    // ist keine Schraeglage. Ohne GPS wird weiter alles gezaehlt.
    final riding = !hasFix || speedMs > 3;
    if (riding && roll.abs() < 85) {
      if (-roll > maxLeanL) maxLeanL = -roll;
      if (roll > maxLeanR) maxLeanR = roll;
    }

    // Direkt an die Anzeige. Kein setState, kein Neuaufbau des
    // Bildschirms - nur der Zeiger zeichnet sich neu.
    if (_leanLive) lean.value = roll;
  }

  void _onPos(Position p) {
    _fixTime = DateTime.now();
    gpsServiceOff = false;
    lat = p.latitude;
    lon = p.longitude;
    altM = p.altitude;
    gpsAccuracyM = p.accuracy;

    final s = (p.speed.isFinite && p.speed >= 0) ? p.speed : 0.0;
    speedMs = speedMs < 0 ? s : speedMs + 0.35 * (s - speedMs);
    if (s > 2 && p.heading.isFinite && p.heading >= 0) headingDeg = p.heading;

    // Erst hier, mit dem frisch aktualisierten Tempo: Die
    // Stillstandspruefung der Sturzerkennung braucht den aktuellen Wert,
    // nicht den des vorigen Fixes.
    _crash.feedSpeed(speedMs * 3.6, _clock.elapsedMilliseconds);

    if (recording) {
      if (speedMs > rideMaxSpeedMs) rideMaxSpeedMs = speedMs;
      _recordPoint(p);
    }

    // Erster Wetterabruf, sobald ueberhaupt eine Position vorliegt.
    if (weather == null) refreshWeather();
  }

  void _recordPoint(Position p) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // Strecke aufaddieren (nur bei brauchbarer Genauigkeit und Bewegung).
    //
    // Vorher wurde vom letzten GESPEICHERTEN Punkt aus gemessen, der aber
    // nur alle 700 ms weiterrueckt. Lieferte das GPS schneller als einmal
    // je 700 ms, wurde derselbe Abschnitt mehrfach gezaehlt - die Strecke
    // war zu lang. Jetzt wird jeder Abschnitt genau einmal gezaehlt.
    if (p.accuracy < 30 && speedMs > 1.0) {
      final la = _lastDistLat, lo = _lastDistLon;
      if (la != null && lo != null) {
        final d = distanceMeters(la, lo, p.latitude, p.longitude);
        final dt = (nowMs - _lastDistMs) / 1000;
        // Grosse Spruenge nur zaehlen, wenn sie zur Zeit passen (etwa
        // nach einem Tunnel), nicht bei einem GPS-Ausreisser.
        if (d < 200 || (dt > 0 && d / dt < 70)) rideDistanceM += d;
      }
      _lastDistLat = p.latitude;
      _lastDistLon = p.longitude;
      _lastDistMs = nowMs;
    }

    // Punkte hoechstens alle 700 ms speichern - reicht fuer eine
    // fluessige Linie und haelt die Dateien klein.
    if (nowMs - _lastRecMs < 700) return;
    _lastRecMs = nowMs;

    track.add(TrackPoint(
      lat: p.latitude,
      lon: p.longitude,
      tMs: nowMs,
      speedMs: speedMs,
      lean: roll,
      altM: p.altitude,
    ));
  }

  /// G-Kraefte im Sensortakt berechnen, nicht im Anzeigetakt: Eine kurze
  /// Bremsspitze faellt sonst zwischen zwei Takte und wird nie gesehen.
  void _updateForces() {
    longG = _frame.forward(_lx, _ly, _lz) / 9.81;
    latG = math.tan(roll.abs() * math.pi / 180).clamp(0.0, 3.0).toDouble();

    final moving = hasFix ? speedMs > 1.5 : true;
    if (moving) {
      final brake = -longG;
      if (brake > maxBrakeG) maxBrakeG = brake;
      if (latG > maxLatG) maxLatG = latG;
    }
  }

  /// Langsamer Takt: nur noch Kacheln und Texte auffrischen.
  /// Im Hintergrund ohne Fahrt gibt es nichts zu tun.
  void _tick() {
    if (!_foreground && !active) return;
    _crash.tick(_clock.elapsedMilliseconds);
    notifyListeners();
  }

  // -----------------------------------------------------------------
  // Wetter
  // -----------------------------------------------------------------
  /// Holt das Wetter fuer die aktuelle Position. Alle 15 Minuten reicht -
  /// das Wetter aendert sich nicht im Sekundentakt, und jeder Aufruf
  /// kostet Akku und Datenvolumen.
  Future<void> refreshWeather({bool force = false}) async {
    // Im Hintergrund ohne Fahrt sieht niemand das Wetter.
    if (!_foreground && !active) return;
    final la = lat, lo = lon;
    if (la == null || lo == null) return;
    if (_weatherBusy) return;
    final nowMs = _clock.elapsedMilliseconds;
    // Vorhandene Daten sind noch frisch genug.
    if (!force && weather != null && nowMs - _weatherAtMs < 900000) return;
    // Nach einem Fehlschlag nicht sofort wieder anklopfen.
    if (!force && _weatherFailMs != 0 && nowMs - _weatherFailMs < 120000) {
      return;
    }
    _weatherBusy = true;
    final w = await WeatherService.fetch(la, lo);
    _weatherBusy = false;
    if (w == null) {
      _weatherFailMs = _clock.elapsedMilliseconds;
      return;
    }
    _weatherFailMs = 0;
    _weatherAtMs = _clock.elapsedMilliseconds;
    weather = w;
    notifyListeners();
  }

  static double _norm(double a) {
    a = (a + 180) % 360;
    if (a < 0) a += 360;
    return a - 180;
  }

  // ---------------------------------------------------------------
  // Aktionen
  // ---------------------------------------------------------------

  /// Setzt den Nullpunkt und bestimmt die Lage des Handys am Motorrad
  /// aus der aktuellen Schwerkraftrichtung. Dadurch darf das Handy
  /// hochkant, quer oder flach und beliebig schraeg montiert sein.
  /// Das Motorrad muss dabei gerade stehen (nicht auf dem Seitenstaender).
  ///
  /// Rueckgabe false: Messwert unbrauchbar (Handy wird gerade bewegt).
  bool calibrate({bool persist = true}) {
    final f = MountFrame.fromGravity(_gx, _gy, _gz);
    if (f == null) return false;
    _frame = f;
    roll = 0;
    _calibrated = true;
    if (persist) unawaited(_saveFrame(f));
    notifyListeners();
    return true;
  }

  static const _kFrame = 'mount_frame';

  Future<MountFrame?> _loadFrame() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getStringList(_kFrame);
      return MountFrame.fromList(raw?.map(double.parse).toList());
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveFrame(MountFrame f) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(
          _kFrame, f.toList().map((v) => v.toString()).toList());
    } catch (_) {}
  }

  void resetMax() {
    maxLeanL = 0;
    maxLeanR = 0;
    maxBrakeG = 0;
    maxLatG = 0;
    notifyListeners();
  }

  void startRecording() {
    recording = true;
    unawaited(_applyPowerMode());
    rideStart = DateTime.now();
    rideDistanceM = 0;
    rideMaxSpeedMs = 0;
    track.clear();
    _lastDistLat = null;
    _lastDistLon = null;
    _lastDistMs = 0;
    _lastRecMs = 0;
    resetMax();
    notifyListeners();
  }

  /// Zusammenfassung der laufenden Fahrt (fuer die Zwischensicherung).
  RideSummary? currentSummary() {
    if (!recording || rideStart == null) return null;
    return _summary();
  }

  RideSummary _summary() => RideSummary(
        id: 'ride_${rideStart!.millisecondsSinceEpoch}',
        start: rideStart!,
        durationSec: DateTime.now().difference(rideStart!).inSeconds,
        distanceM: rideDistanceM,
        maxLeanL: maxLeanL,
        maxLeanR: maxLeanR,
        maxSpeedMs: rideMaxSpeedMs,
        maxBrakeG: maxBrakeG,
        maxLatG: maxLatG,
        pointCount: track.length,
      );

  /// Beendet die Aufzeichnung und liefert die Zusammenfassung.
  /// Das Speichern uebernimmt der RideStore.
  RideSummary? stopRecording() {
    if (!recording || rideStart == null) return null;
    recording = false;
    unawaited(_applyPowerMode());
    final s = _summary();
    notifyListeners();
    return s;
  }
}

/// Wie das GPS gerade laeuft.
enum GpsMode {
  /// Aus (App im Hintergrund, keine Fahrt).
  off,

  /// Sparsam: App offen, keine Fahrt.
  idle,

  /// Voll, als Vordergrunddienst: Fahrt oder Navigation.
  ride,
}

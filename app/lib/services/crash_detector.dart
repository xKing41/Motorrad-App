import 'dart:math' as math;

/// Erkennt einen moeglichen Sturz aus den Sensordaten, die ohnehin schon
/// laufen. Kein zusaetzliches Sensor-Abo, kein Server.
///
/// ---------------------------------------------------------------------
///  ERKENNUNGSLOGIK - und warum sie so und nicht einfacher ist
/// ---------------------------------------------------------------------
///  Ein Aufprall allein reicht als Kennzeichen nicht: Ein Schlagloch,
///  ein zugeklapptes Handy oder ein Sturz des Handys vom Lenker im Stand
///  erzeugen ebenfalls hohe Werte. Deshalb muessen VIER Bedingungen
///  zusammenkommen:
///
///   1. Vorher gefahren  - kurz zuvor mindestens [armSpeedKmh] unterwegs
///   2. Harter Aufprall  - Beschleunigung ueber [impactG]
///   3. Danach Stillstand - fuer [stillSec] Sekunden keine Bewegung
///      (per GPS; ist das GPS nach dem Aufprall weg - Handy unter dem
///      Motorrad -, zaehlt der Beschleunigungssensor)
///   4. Lage veraendert - das Handy liegt danach deutlich anders als
///      vorher (Motorrad liegt, Handy weggeflogen). Das verhindert den
///      haeufigsten Fehlalarm: harter Schlag (Kante, Schlagloch) beim
///      Ausrollen, dann Warten an der Ampel.
///
///  Erst dann wird Alarm gemeldet. Der Alarm selbst schickt noch nichts
///  ab, sondern startet einen Countdown, den der Fahrer abbrechen kann.
///
///  WICHTIG: Das ist eine Hilfe, kein zugelassenes Notrufsystem. Es kann
///  einen Sturz uebersehen (z. B. sanftes Wegrutschen ohne harten
///  Aufprall, oder das Motorrad bleibt stehen und nur der Fahrer faellt)
///  und es kann Fehlalarme geben.
/// ---------------------------------------------------------------------
class CrashDetector {
  CrashDetector({required this.onSuspectedCrash});

  /// Wird genau einmal je Ereignis gerufen.
  final void Function() onSuspectedCrash;

  // --- Schwellwerte ---
  /// Manche Handys messen nur bis 4 g - ein Schwellwert von genau 4 g
  /// wuerde dort nie erreicht.
  static const double impactG = 3.5;
  static const double armSpeedKmh = 25; // vorher mindestens so schnell
  static const int armWindowMs = 60000; // "kurz zuvor" = 60 s
  static const double stillSpeedKmh = 5; // gilt als Stillstand
  static const int stillSec = 8; // so lange bewegungslos
  static const int cooldownMs = 120000; // 2 min Sperre nach Alarm
  static const double tiltDeg = 35; // Lageaenderung fuer "gestuerzt"
  static const int gpsLostMs = 4000; // ab hier gilt das GPS als weg
  static const int giveUpMs = 90000; // Verdacht verfaellt danach

  bool enabled = true;

  int _lastFastMs = 0;
  int _impactMs = 0;
  // Kein "letzter Alarm" beim Start - vorher war die Erkennung in den
  // ersten zwei Minuten nach dem App-Start dadurch abgeschaltet.
  int _lastAlarmMs = -cooldownMs;
  int _stillSinceMs = 0;
  int _lastSpeedMs = 0;
  double _lastSpeedKmh = 0;

  // Lage (geglaettete Schwerkraft) und Ruhe laut Beschleunigungssensor.
  List<double> _gravity = const [0, 9.81, 0];
  List<double>? _gravityBefore;
  int _accStillSinceMs = 0;

  /// Zustand fuer die Anzeige.
  bool get armed => _lastFastMs > 0;
  bool get watching => _impactMs > 0;

  void reset() {
    _impactMs = 0;
    _stillSinceMs = 0;
    _gravityBefore = null;
  }

  /// Geglaettete Schwerkraftrichtung (m/s^2) - wie das Handy gerade liegt.
  void feedGravity(double x, double y, double z) {
    _gravity = [x, y, z];
  }

  /// Rohe Beschleunigung inklusive Schwerkraft, in m/s^2.
  /// Wird aus dem bereits laufenden Sensor-Abo gefuettert.
  void feedAccel(double x, double y, double z, int nowMs) {
    if (!enabled) return;
    final g = math.sqrt(x * x + y * y + z * z) / 9.81;

    // Ruhe laut Sensor: nahe 1 g, ohne Erschuetterung.
    if ((g - 1).abs() > 0.25 || _accStillSinceMs == 0) {
      _accStillSinceMs = nowMs;
    }

    // Nur ein Aufprall zaehlt, und nur wenn kurz zuvor gefahren wurde.
    if (g >= impactG &&
        _impactMs == 0 &&
        _lastFastMs > 0 &&
        nowMs - _lastFastMs <= armWindowMs &&
        nowMs - _lastAlarmMs > cooldownMs) {
      _impactMs = nowMs;
      _stillSinceMs = 0;
      // Die Schwerkraft ist traege geglaettet - sie zeigt hier noch die
      // Lage VOR dem Aufprall.
      _gravityBefore = List.of(_gravity);
    }
  }

  /// Aktuelle Geschwindigkeit aus dem GPS.
  void feedSpeed(double speedKmh, int nowMs) {
    if (!enabled) return;
    _lastSpeedKmh = speedKmh;
    _lastSpeedMs = nowMs;

    if (speedKmh >= armSpeedKmh) {
      _lastFastMs = nowMs;
      // Wieder unterwegs: ein laufender Verdacht ist damit erledigt.
      if (_impactMs != 0) reset();
      return;
    }

    if (_impactMs == 0) return;

    // Nach dem Aufprall auf Stillstand pruefen.
    if (speedKmh <= stillSpeedKmh) {
      if (_stillSinceMs == 0) _stillSinceMs = nowMs;
      if (nowMs - _stillSinceMs >= stillSec * 1000) _decide(nowMs);
    } else {
      // Bewegt sich wieder: kein Sturz.
      _stillSinceMs = 0;
    }
  }

  /// Regelmaessig aufrufen (auch ohne GPS).
  void tick(int nowMs) {
    if (_impactMs == 0) return;
    if (nowMs - _impactMs > giveUpMs) {
      reset();
      return;
    }
    // GPS nach dem Aufprall weg (Handy unter dem Motorrad, im Graben):
    // dann entscheidet der Beschleunigungssensor ueber "Stillstand".
    final gpsGone = nowMs - _lastSpeedMs > gpsLostMs;
    if (gpsGone &&
        nowMs - _impactMs >= stillSec * 1000 &&
        nowMs - _accStillSinceMs >= stillSec * 1000) {
      _decide(nowMs);
    }
  }

  /// Stillstand nach dem Aufprall ist bestaetigt - liegt das Handy
  /// jetzt anders als vorher?
  void _decide(int nowMs) {
    final before = _gravityBefore;
    final tilted = before == null || angleDeg(before, _gravity) >= tiltDeg;
    reset();
    if (!tilted) return; // Aufrecht stehen geblieben: Ampel, kein Sturz.
    _lastAlarmMs = nowMs;
    onSuspectedCrash();
  }

  static double angleDeg(List<double> a, List<double> b) {
    final na = math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    final nb = math.sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2]);
    if (na == 0 || nb == 0) return 0;
    final c = ((a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (na * nb))
        .clamp(-1.0, 1.0);
    return math.acos(c) * 180 / math.pi;
  }

  double get lastSpeedKmh => _lastSpeedKmh;
}

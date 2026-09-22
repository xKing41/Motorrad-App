import 'dart:math' as math;

/// Erkennt einen moeglichen Sturz aus den Sensordaten, die ohnehin schon
/// laufen. Kein zusaetzliches Sensor-Abo, kein Server.
///
/// ---------------------------------------------------------------------
///  ERKENNUNGSLOGIK - und warum sie so und nicht einfacher ist
/// ---------------------------------------------------------------------
///  Ein Aufprall allein reicht als Kennzeichen nicht: Ein Schlagloch,
///  ein zugeklapptes Handy oder ein Sturz des Handys vom Lenker im Stand
///  erzeugen ebenfalls hohe Werte. Deshalb muessen DREI Bedingungen
///  zusammenkommen:
///
///   1. Vorher gefahren  - kurz zuvor mindestens [_armSpeedKmh] unterwegs
///   2. Harter Aufprall  - Beschleunigung ueber [_impactG]
///   3. Danach Stillstand - fuer [_stillSec] Sekunden praktisch bewegungslos
///
///  Erst dann wird Alarm gemeldet. Der Alarm selbst schickt noch nichts
///  ab, sondern startet einen Countdown, den der Fahrer abbrechen kann.
///
///  WICHTIG: Das ist eine Hilfe, kein zugelassenes Notrufsystem. Es kann
///  einen Sturz uebersehen (z. B. sanftes Wegrutschen ohne harten
///  Aufprall) und es kann Fehlalarme geben.
/// ---------------------------------------------------------------------
class CrashDetector {
  CrashDetector({required this.onSuspectedCrash});

  /// Wird genau einmal je Ereignis gerufen.
  final void Function() onSuspectedCrash;

  // --- Schwellwerte ---
  static const double _impactG = 4.0; // Aufprall ab 4 g
  static const double _armSpeedKmh = 25; // vorher mindestens so schnell
  static const int _armWindowMs = 60000; // "kurz zuvor" = 60 s
  static const double _stillSpeedKmh = 5; // gilt als Stillstand
  static const int _stillSec = 8; // so lange bewegungslos
  static const int _cooldownMs = 120000; // 2 min Sperre nach Alarm

  bool enabled = true;

  int _lastFastMs = 0;
  int _impactMs = 0;
  int _lastAlarmMs = 0;
  int _stillSinceMs = 0;
  double _lastSpeedKmh = 0;

  /// Zustand fuer die Anzeige.
  bool get armed => _lastFastMs > 0;
  bool get watching => _impactMs > 0;

  void reset() {
    _impactMs = 0;
    _stillSinceMs = 0;
  }

  /// Rohe Beschleunigung inklusive Schwerkraft, in m/s^2.
  /// Wird aus dem bereits laufenden Sensor-Abo gefuettert.
  void feedAccel(double x, double y, double z, int nowMs) {
    if (!enabled) return;
    final g = math.sqrt(x * x + y * y + z * z) / 9.81;

    // Nur ein Aufprall zaehlt, und nur wenn kurz zuvor gefahren wurde.
    if (g >= _impactG &&
        _impactMs == 0 &&
        _lastFastMs > 0 &&
        nowMs - _lastFastMs <= _armWindowMs &&
        nowMs - _lastAlarmMs > _cooldownMs) {
      _impactMs = nowMs;
      _stillSinceMs = 0;
    }
  }

  /// Aktuelle Geschwindigkeit aus dem GPS.
  void feedSpeed(double speedKmh, int nowMs) {
    if (!enabled) return;
    _lastSpeedKmh = speedKmh;

    if (speedKmh >= _armSpeedKmh) {
      _lastFastMs = nowMs;
      // Wieder unterwegs: ein laufender Verdacht ist damit erledigt.
      if (_impactMs != 0) reset();
      return;
    }

    if (_impactMs == 0) return;

    // Nach dem Aufprall auf Stillstand pruefen.
    if (speedKmh <= _stillSpeedKmh) {
      if (_stillSinceMs == 0) _stillSinceMs = nowMs;
      if (nowMs - _stillSinceMs >= _stillSec * 1000) {
        _lastAlarmMs = nowMs;
        reset();
        onSuspectedCrash();
      }
    } else {
      // Bewegt sich wieder: kein Sturz.
      _stillSinceMs = 0;
    }
  }

  /// Manuelle Prüfung: Wird gerufen, wenn laenger kein GPS-Wert kommt,
  /// damit ein Verdacht nicht endlos offen bleibt.
  void tick(int nowMs) {
    if (_impactMs == 0) return;
    // Ohne GPS-Werte kann kein Stillstand bestaetigt werden. Nach einer
    // Minute den Verdacht verwerfen, statt spaeter grundlos Alarm zu
    // schlagen.
    if (nowMs - _impactMs > 60000) reset();
  }

  double get lastSpeedKmh => _lastSpeedKmh;
}
